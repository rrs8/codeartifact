package com.chainguard.demo.service;

import com.chainguard.demo.model.*;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.*;
import java.nio.file.*;
import java.security.MessageDigest;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.*;
import java.util.concurrent.*;
import java.util.jar.JarEntry;
import java.util.jar.JarFile;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Collectors;

public class ChainctlService {
    private static final Logger log = LoggerFactory.getLogger(ChainctlService.class);
    private static final ObjectMapper objectMapper = new ObjectMapper();

    private final String defaultGroup = System.getenv("CHAINCTL_DEFAULT_GROUP");
    private final String libsDir = System.getenv().getOrDefault("CHAINCTL_LIBS_DIR", "/app/libs");

    // Global state for verification progress
    private volatile VerificationProgress progress = new VerificationProgress();
    private volatile VerificationResult cachedResult = null;
    private volatile String lastRunTimestamp = null;
    private volatile String normalOutput = "";
    private volatile String verboseOutput = "";

    private final ExecutorService executor = Executors.newFixedThreadPool(10);
    private volatile boolean tokensInitialized = false;

    /**
     * Initialize chainctl tokens from environment variables.
     * Writes tokens to the cache directory that chainctl expects.
     */
    private synchronized void setupChainctlTokens() {
        if (tokensInitialized) {
            return;
        }

        String oidcToken = System.getenv("CHAINCTL_OIDC_TOKEN");
        String refreshToken = System.getenv("CHAINCTL_REFRESH_TOKEN");

        if (oidcToken == null || oidcToken.isEmpty()) {
            log.warn("CHAINCTL_OIDC_TOKEN not set, chainctl may fail to authenticate");
            tokensInitialized = true;
            return;
        }

        try {
            // Create the cache directory structure chainctl expects
            String home = System.getenv("HOME");
            if (home == null) {
                home = System.getProperty("user.home");
            }
            Path cacheDir = Paths.get(home, ".cache", "chainguard", "https:--console-api.enforce.dev");
            Files.createDirectories(cacheDir);

            // Write the OIDC token
            Path oidcPath = cacheDir.resolve("oidc-token");
            Files.writeString(oidcPath, oidcToken);
            // Set file permissions to 600 (owner read/write only)
            oidcPath.toFile().setReadable(false, false);
            oidcPath.toFile().setWritable(false, false);
            oidcPath.toFile().setReadable(true, true);
            oidcPath.toFile().setWritable(true, true);

            // Write the refresh token if present
            if (refreshToken != null && !refreshToken.isEmpty()) {
                Path refreshPath = cacheDir.resolve("refresh-token");
                Files.writeString(refreshPath, refreshToken);
                refreshPath.toFile().setReadable(false, false);
                refreshPath.toFile().setWritable(false, false);
                refreshPath.toFile().setReadable(true, true);
                refreshPath.toFile().setWritable(true, true);
            }

            log.info("Successfully initialized chainctl tokens in {}", cacheDir);
            tokensInitialized = true;
        } catch (Exception e) {
            log.error("Failed to setup chainctl tokens: {}", e.getMessage());
        }
    }

    /**
     * Check if chainctl is authenticated
     */
    public AuthStatus checkAuthStatus() {
        AuthStatus status = new AuthStatus();
        try {
            ProcessBuilder pb = new ProcessBuilder("chainctl", "auth", "status", "-o", "json");
            pb.redirectErrorStream(true);
            Process process = pb.start();

            String output = readProcessOutput(process);
            int exitCode = process.waitFor();

            if (exitCode == 0 && !output.isEmpty()) {
                try {
                    objectMapper.readTree(output);
                    status.setAuthenticated(true);
                } catch (Exception e) {
                    status.setAuthenticated(false);
                }
            } else {
                status.setAuthenticated(false);
            }
        } catch (Exception e) {
            log.warn("Failed to check auth status: {}", e.getMessage());
            status.setAuthenticated(false);
            status.setError(e.getMessage());
        }
        return status;
    }

    /**
     * Get cached verification results or run new verification
     */
    public VerificationResult getVerificationResults() throws Exception {
        if (cachedResult != null) {
            return cachedResult;
        }
        return runVerification();
    }

    /**
     * Get current verification progress
     */
    public VerificationProgress getProgress() {
        return progress;
    }

    /**
     * Get chainctl logs
     */
    public Map<String, String> getLogs() {
        Map<String, String> logs = new HashMap<>();
        logs.put("normal_output", normalOutput);
        logs.put("verbose_output", verboseOutput);
        logs.put("last_run", lastRunTimestamp);
        return logs;
    }

    /**
     * Run chainctl verification on all JARs in parallel
     */
    public VerificationResult runVerification() throws Exception {
        // Ensure chainctl tokens are written to cache before running verification
        setupChainctlTokens();

        String parentOrg = getParentOrg();
        if (parentOrg == null || parentOrg.isEmpty()) {
            VerificationResult result = new VerificationResult();
            result.setError("CHAINCTL_DEFAULT_GROUP not set. Please run: chainctl config set default.group <your.chainguardorg.dev> and rebuild.");
            return result;
        }

        Path libsPath = Paths.get(libsDir);
        if (!Files.exists(libsPath)) {
            VerificationResult result = new VerificationResult();
            result.setError("Libs directory not found: " + libsDir);
            return result;
        }

        List<Path> jarFiles = Files.list(libsPath)
                .filter(p -> p.toString().endsWith(".jar"))
                .sorted()
                .collect(Collectors.toList());

        if (jarFiles.isEmpty()) {
            VerificationResult result = new VerificationResult();
            result.setError("No JAR files found in " + libsDir);
            return result;
        }

        int total = jarFiles.size();
        log.info("Running parallel verification on {} JARs (max 10 concurrent)", total);

        // Initialize progress
        progress = new VerificationProgress(0, total, "running");

        // Run verifications in parallel
        List<Future<JsonNode>> futures = new ArrayList<>();
        for (Path jarPath : jarFiles) {
            futures.add(executor.submit(() -> verifySingleJar(jarPath, parentOrg)));
        }

        // Collect results
        List<JsonNode> allResults = new ArrayList<>();
        for (int i = 0; i < futures.size(); i++) {
            try {
                JsonNode result = futures.get(i).get(60, TimeUnit.SECONDS);
                allResults.add(result);
                synchronized (this) {
                    progress.setCompleted(progress.getCompleted() + 1);
                }
                log.info("Verified {}/{}: {}", progress.getCompleted(), total, jarFiles.get(i).getFileName());
            } catch (Exception e) {
                log.error("Verification failed for {}: {}", jarFiles.get(i).getFileName(), e.getMessage());
            }
        }

        progress.setStatus("complete");

        // Store logs
        StringBuilder cmdHeader = new StringBuilder();
        cmdHeader.append("$ chainctl libraries verify -o json --detailed --parent ")
                 .append(parentOrg)
                 .append(" /app/libs/*.jar\n\n");
        normalOutput = cmdHeader + objectMapper.writerWithDefaultPrettyPrinter().writeValueAsString(allResults);
        lastRunTimestamp = LocalDateTime.now().format(DateTimeFormatter.ofPattern("EEE MMM dd HH:mm:ss yyyy"));

        // Merge and parse results
        VerificationResult merged = mergeVerificationResults(allResults);
        cachedResult = merged;
        return merged;
    }

    /**
     * Verify a single JAR file
     */
    private JsonNode verifySingleJar(Path jarPath, String parentOrg) throws Exception {
        ProcessBuilder pb = new ProcessBuilder(
                "chainctl", "libraries", "verify",
                "-o", "json", "--detailed",
                "--parent", parentOrg,
                jarPath.toString()
        );

        Process process = pb.start();

        // Read stdout and stderr in separate threads to avoid blocking
        CompletableFuture<String> stdoutFuture = CompletableFuture.supplyAsync(() -> {
            try {
                return readProcessOutput(process);
            } catch (IOException e) {
                return "";
            }
        });
        CompletableFuture<String> stderrFuture = CompletableFuture.supplyAsync(() -> {
            try {
                return readErrorOutput(process);
            } catch (IOException e) {
                return "";
            }
        });

        boolean finished = process.waitFor(45, TimeUnit.SECONDS);

        if (!finished) {
            process.destroyForcibly();
            throw new TimeoutException("chainctl verification timed out after 45 seconds for: " + jarPath.getFileName());
        }

        String stdout = stdoutFuture.get(5, TimeUnit.SECONDS);
        String stderr = stderrFuture.get(5, TimeUnit.SECONDS);
        int exitCode = process.exitValue();

        if (exitCode == 0 && !stdout.isEmpty()) {
            return objectMapper.readTree(stdout);
        } else {
            // Return error object
            Map<String, String> error = new HashMap<>();
            error.put("error", stderr.isEmpty() ? "Unknown error" : stderr);
            error.put("path", jarPath.toString());
            return objectMapper.valueToTree(error);
        }
    }

    /**
     * Merge individual verification results into combined format
     */
    private VerificationResult mergeVerificationResults(List<JsonNode> results) {
        VerificationResult merged = new VerificationResult();
        double totalCoverage = 0;

        for (JsonNode result : results) {
            if (result.has("error")) {
                PackageInfo pkg = new PackageInfo();
                pkg.setFilename(result.path("path").asText("unknown"));
                pkg.setVerified(false);
                pkg.setDetails(result.path("error").asText("Unknown error"));
                merged.addPackage(pkg);
            } else if (result.has("artifact")) {
                // Single-package result format
                PackageInfo pkg = parseArtifactResult(result);
                merged.addPackage(pkg);
                totalCoverage += result.path("artifactVerificationCoverage").asDouble(0);
            }
        }

        merged.setTotalCount(merged.getPackages().size());
        merged.setVerifiedCount((int) merged.getPackages().stream().filter(PackageInfo::isVerified).count());

        if (!results.isEmpty()) {
            merged.setArtifactCoverage(totalCoverage / results.size());
            merged.setOverallCoverage(merged.getArtifactCoverage());
        }

        return merged;
    }

    /**
     * Parse a single artifact verification result
     */
    private PackageInfo parseArtifactResult(JsonNode artifact) {
        PackageInfo pkg = new PackageInfo();

        String artifactPath = artifact.path("artifact").asText("");
        String filename = Paths.get(artifactPath).getFileName().toString();
        pkg.setFilename(filename);

        // Parse JAR filename to extract coordinates
        // Format: artifactId-version.jar or artifactId-version-classifier.jar
        parseJarFilename(pkg, filename);

        // Check verification status
        double coverage = artifact.path("artifactVerificationCoverage").asDouble(0);
        boolean isVerified = coverage == 100;
        pkg.setVerified(isVerified);
        pkg.setVerificationMethod(isVerified ? "signature" : "none");

        String details = artifact.path("details").asText("");
        pkg.setDetails(details);

        // Extract Rekor URL if verified
        if (isVerified && details.contains("rekor.sigstore.dev")) {
            Pattern pattern = Pattern.compile("(https://rekor\\.sigstore\\.dev/api/v1/log/entries/\\?logIndex=\\d+)");
            Matcher matcher = pattern.matcher(details);
            if (matcher.find()) {
                pkg.setRekorUrl(matcher.group(1));
            } else {
                Pattern indexPattern = Pattern.compile("logIndex[=:\\s]+(\\d+)");
                Matcher indexMatcher = indexPattern.matcher(details);
                if (indexMatcher.find()) {
                    pkg.setRekorUrl("https://search.sigstore.dev/?logIndex=" + indexMatcher.group(1));
                }
            }
        }

        return pkg;
    }

    /**
     * Parse JAR filename to extract Maven coordinates
     */
    private void parseJarFilename(PackageInfo pkg, String filename) {
        if (!filename.endsWith(".jar")) {
            pkg.setArtifactId(filename);
            return;
        }

        // Remove .jar extension
        String name = filename.substring(0, filename.length() - 4);

        // Try to find version pattern (numbers with dots, optionally followed by -classifier)
        Pattern versionPattern = Pattern.compile("^(.+)-(\\d+\\.\\d+[\\d.]*(?:-[A-Za-z0-9]+)?)$");
        Matcher matcher = versionPattern.matcher(name);

        if (matcher.matches()) {
            pkg.setArtifactId(matcher.group(1));
            pkg.setVersion(matcher.group(2));
        } else {
            pkg.setArtifactId(name);
            pkg.setVersion("");
        }

        // Note: groupId cannot be determined from JAR filename alone
        // It would need to be read from pom.properties inside the JAR
        pkg.setGroupId("");
    }

    /**
     * Get JAR file contents
     */
    public JarContents getJarContents(String artifactId, String version) {
        JarContents contents = new JarContents();
        contents.setArtifactId(artifactId);
        contents.setVersion(version);

        try {
            Path jarPath = findJarFile(artifactId, version);
            if (jarPath == null) {
                contents.setError("JAR file not found for " + artifactId + " " + version);
                return contents;
            }

            contents.setJarFile(jarPath.getFileName().toString());

            try (JarFile jarFile = new JarFile(jarPath.toFile())) {
                List<JarContents.FileInfo> files = new ArrayList<>();
                long totalSize = 0;

                Enumeration<JarEntry> entries = jarFile.entries();
                while (entries.hasMoreElements()) {
                    JarEntry entry = entries.nextElement();
                    JarContents.FileInfo fileInfo = new JarContents.FileInfo(
                            entry.getName(),
                            entry.getSize(),
                            entry.getCompressedSize(),
                            entry.isDirectory()
                    );
                    files.add(fileInfo);
                    totalSize += entry.getSize();
                }

                contents.setFiles(files);
                contents.setTotalFiles(files.size());
                contents.setTotalSize(totalSize);
                contents.setTree(buildFileTree(files));
            }
        } catch (Exception e) {
            contents.setError(e.getMessage());
        }

        return contents;
    }

    /**
     * Calculate SHA256 hash of a JAR file for Rekor lookups
     */
    public Map<String, String> getJarHash(String artifactId, String version) {
        Map<String, String> result = new HashMap<>();
        try {
            Path jarPath = findJarFile(artifactId, version);
            if (jarPath == null) {
                return null;
            }

            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            byte[] fileBytes = Files.readAllBytes(jarPath);
            byte[] hashBytes = digest.digest(fileBytes);

            StringBuilder hexString = new StringBuilder();
            for (byte b : hashBytes) {
                String hex = Integer.toHexString(0xff & b);
                if (hex.length() == 1) hexString.append('0');
                hexString.append(hex);
            }

            String sha256 = hexString.toString();
            result.put("sha256", sha256);
            result.put("rekor_url", "https://search.sigstore.dev/?hash=" + sha256);
        } catch (Exception e) {
            log.error("Failed to calculate hash: {}", e.getMessage());
            return null;
        }
        return result;
    }

    /**
     * Find JAR file by artifactId and version
     */
    private Path findJarFile(String artifactId, String version) throws IOException {
        Path libsPath = Paths.get(libsDir);
        if (!Files.exists(libsPath)) {
            return null;
        }

        String pattern = artifactId + "-" + version + "*.jar";
        try (var stream = Files.list(libsPath)) {
            return stream
                    .filter(p -> {
                        String name = p.getFileName().toString();
                        return name.startsWith(artifactId + "-" + version) && name.endsWith(".jar");
                    })
                    .findFirst()
                    .orElse(null);
        }
    }

    /**
     * Build hierarchical tree structure from flat file list
     */
    private Map<String, Object> buildFileTree(List<JarContents.FileInfo> files) {
        Map<String, Object> tree = new LinkedHashMap<>();

        for (JarContents.FileInfo file : files) {
            String[] parts = file.getPath().split("/");
            Map<String, Object> current = tree;

            for (int i = 0; i < parts.length; i++) {
                String part = parts[i];
                if (part.isEmpty()) continue;

                if (i == parts.length - 1) {
                    // Leaf node
                    Map<String, Object> leaf = new LinkedHashMap<>();
                    leaf.put("type", file.isDir() ? "dir" : "file");
                    leaf.put("size", file.getSize());
                    leaf.put("path", file.getPath());
                    current.put(part, leaf);
                } else {
                    // Directory node
                    if (!current.containsKey(part)) {
                        Map<String, Object> dir = new LinkedHashMap<>();
                        dir.put("type", "dir");
                        dir.put("children", new LinkedHashMap<String, Object>());
                        current.put(part, dir);
                    }
                    @SuppressWarnings("unchecked")
                    Map<String, Object> dir = (Map<String, Object>) current.get(part);
                    @SuppressWarnings("unchecked")
                    Map<String, Object> children = (Map<String, Object>) dir.get("children");
                    if (children == null) {
                        children = new LinkedHashMap<>();
                        dir.put("children", children);
                    }
                    current = children;
                }
            }
        }

        return tree;
    }

    /**
     * Get parent organization from environment
     */
    private String getParentOrg() {
        if (defaultGroup != null && !defaultGroup.isEmpty()) {
            return defaultGroup;
        }
        return System.getenv("CHAINCTL_DEFAULT_GROUP");
    }

    private String readProcessOutput(Process process) throws IOException {
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(process.getInputStream()))) {
            return reader.lines().collect(Collectors.joining("\n"));
        }
    }

    private String readErrorOutput(Process process) throws IOException {
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(process.getErrorStream()))) {
            return reader.lines().collect(Collectors.joining("\n"));
        }
    }
}
