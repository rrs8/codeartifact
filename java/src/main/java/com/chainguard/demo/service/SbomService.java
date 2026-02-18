package com.chainguard.demo.service;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.*;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.jar.JarEntry;
import java.util.jar.JarFile;

public class SbomService {
    private static final Logger log = LoggerFactory.getLogger(SbomService.class);
    private static final ObjectMapper objectMapper = new ObjectMapper();

    private final String librariesBaseUrl = System.getenv().getOrDefault("CHAINGUARD_LIBRARIES_URL", "https://libraries.cgr.dev/java");
    private final String libsDir = System.getenv().getOrDefault("CHAINCTL_LIBS_DIR", "/app/libs");

    /**
     * Fetch SBOM for a package from Chainguard Libraries API
     * URL format: https://libraries.cgr.dev/java/{groupPath}/{artifactId}/{version}/{artifactId}-{version}.spdx.json
     */
    public Map<String, Object> getSbom(String groupId, String artifactId, String version) {
        Map<String, Object> result = new HashMap<>();

        try {
            // If groupId is empty, try to extract it from the JAR's pom.properties
            if (groupId == null || groupId.isEmpty()) {
                groupId = extractGroupIdFromJar(artifactId, version);
            }

            if (groupId == null || groupId.isEmpty()) {
                result.put("error", "Could not determine groupId for " + artifactId);
                return result;
            }

            String groupPath = groupId.replace('.', '/');
            String sbomUrl = String.format("%s/%s/%s/%s/%s-%s.spdx.json",
                    librariesBaseUrl, groupPath, artifactId, version, artifactId, version);

            log.info("Fetching SBOM from: {}", sbomUrl);

            String sbomJson = fetchWithNetrcAuth(sbomUrl);
            if (sbomJson != null) {
                JsonNode sbom = objectMapper.readTree(sbomJson);
                result.put("sbom", sbom);
                result.put("url", sbomUrl);

                // Extract key information
                extractSbomInfo(result, sbom, groupId, artifactId, version);
            } else {
                result.put("error", "SBOM not available for " + artifactId + " " + version);
                result.put("url", sbomUrl);
            }
        } catch (Exception e) {
            log.error("Failed to fetch SBOM: {}", e.getMessage());
            result.put("error", e.getMessage());
        }

        return result;
    }

    /**
     * Fetch SLSA provenance attestation for a package
     * URL format: https://libraries.cgr.dev/java/{groupPath}/{artifactId}/{version}/{artifactId}-{version}.slsa-attestation.json
     */
    public Map<String, Object> getProvenance(String groupId, String artifactId, String version) {
        Map<String, Object> result = new HashMap<>();

        try {
            if (groupId == null || groupId.isEmpty()) {
                groupId = extractGroupIdFromJar(artifactId, version);
            }

            if (groupId == null || groupId.isEmpty()) {
                result.put("error", "Could not determine groupId for " + artifactId);
                return result;
            }

            String groupPath = groupId.replace('.', '/');
            String provenanceUrl = String.format("%s/%s/%s/%s/%s-%s.slsa-attestation.json",
                    librariesBaseUrl, groupPath, artifactId, version, artifactId, version);

            log.info("Fetching provenance from: {}", provenanceUrl);

            String provenanceJson = fetchWithNetrcAuth(provenanceUrl);
            if (provenanceJson != null) {
                JsonNode provenance = objectMapper.readTree(provenanceJson);
                result.put("provenance", provenance);
                result.put("url", provenanceUrl);

                // Extract and decode the SLSA predicate
                extractProvenanceInfo(result, provenance);
            } else {
                result.put("error", "Provenance not available for " + artifactId + " " + version);
                result.put("url", provenanceUrl);
            }
        } catch (Exception e) {
            log.error("Failed to fetch provenance: {}", e.getMessage());
            result.put("error", e.getMessage());
        }

        return result;
    }

    /**
     * Extract groupId from JAR's pom.properties file
     */
    private String extractGroupIdFromJar(String artifactId, String version) {
        try {
            Path jarPath = findJarFile(artifactId, version);
            if (jarPath == null) {
                return null;
            }

            try (JarFile jarFile = new JarFile(jarPath.toFile())) {
                // Look for pom.properties in META-INF/maven/{groupId}/{artifactId}/
                Enumeration<JarEntry> entries = jarFile.entries();
                while (entries.hasMoreElements()) {
                    JarEntry entry = entries.nextElement();
                    String name = entry.getName();
                    if (name.endsWith("/pom.properties") && name.contains("META-INF/maven/")) {
                        try (InputStream is = jarFile.getInputStream(entry);
                             BufferedReader reader = new BufferedReader(new InputStreamReader(is))) {
                            Properties props = new Properties();
                            props.load(reader);
                            String groupId = props.getProperty("groupId");
                            if (groupId != null) {
                                return groupId;
                            }
                        }
                    }
                }
            }
        } catch (Exception e) {
            log.warn("Failed to extract groupId from JAR: {}", e.getMessage());
        }
        return null;
    }

    /**
     * Find JAR file by artifactId and version
     */
    private Path findJarFile(String artifactId, String version) throws IOException {
        Path libsPath = Paths.get(libsDir);
        if (!Files.exists(libsPath)) {
            return null;
        }

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
     * Fetch URL content using .netrc credentials
     */
    private String fetchWithNetrcAuth(String urlString) {
        try {
            URL url = new URL(urlString);
            HttpURLConnection conn = (HttpURLConnection) url.openConnection();
            conn.setRequestMethod("GET");
            conn.setRequestProperty("User-Agent", "curl/8.0");

            // Read .netrc credentials
            String[] credentials = readNetrcCredentials("libraries.cgr.dev");
            if (credentials != null) {
                String auth = credentials[0] + ":" + credentials[1];
                String encodedAuth = Base64.getEncoder().encodeToString(auth.getBytes(StandardCharsets.UTF_8));
                conn.setRequestProperty("Authorization", "Basic " + encodedAuth);
            }

            conn.setConnectTimeout(10000);
            conn.setReadTimeout(30000);

            int responseCode = conn.getResponseCode();
            if (responseCode >= 200 && responseCode < 300) {
                try (BufferedReader reader = new BufferedReader(new InputStreamReader(conn.getInputStream()))) {
                    StringBuilder response = new StringBuilder();
                    String line;
                    while ((line = reader.readLine()) != null) {
                        response.append(line);
                    }
                    return response.toString();
                }
            } else {
                log.warn("HTTP {} for {}", responseCode, urlString);
                return null;
            }
        } catch (Exception e) {
            log.error("Failed to fetch {}: {}", urlString, e.getMessage());
            return null;
        }
    }

    /**
     * Read credentials from .netrc file
     */
    private String[] readNetrcCredentials(String machine) {
        try {
            Path netrcPath = Paths.get(System.getProperty("user.home"), ".netrc");
            if (!Files.exists(netrcPath)) {
                // Try current directory
                netrcPath = Paths.get(".netrc");
            }
            if (!Files.exists(netrcPath)) {
                return null;
            }

            List<String> lines = Files.readAllLines(netrcPath);
            String currentMachine = null;
            String login = null;
            String password = null;

            for (String line : lines) {
                line = line.trim();
                String[] parts = line.split("\\s+");

                for (int i = 0; i < parts.length; i++) {
                    if ("machine".equals(parts[i]) && i + 1 < parts.length) {
                        currentMachine = parts[i + 1];
                        login = null;
                        password = null;
                        i++;
                    } else if ("login".equals(parts[i]) && i + 1 < parts.length) {
                        login = parts[i + 1];
                        i++;
                    } else if ("password".equals(parts[i]) && i + 1 < parts.length) {
                        password = parts[i + 1];
                        i++;
                    }
                }

                if (machine.equals(currentMachine) && login != null && password != null) {
                    return new String[]{login, password};
                }
            }
        } catch (Exception e) {
            log.warn("Failed to read .netrc: {}", e.getMessage());
        }
        return null;
    }

    /**
     * Extract key information from SBOM
     */
    private void extractSbomInfo(Map<String, Object> result, JsonNode sbom, String groupId, String artifactId, String version) {
        Map<String, Object> info = new HashMap<>();

        // SPDX format info
        info.put("spdxVersion", sbom.path("spdxVersion").asText(""));
        info.put("name", sbom.path("name").asText(""));
        info.put("creationInfo", sbom.path("creationInfo"));

        // Extract packages
        JsonNode packages = sbom.path("packages");
        if (packages.isArray()) {
            List<Map<String, String>> pkgList = new ArrayList<>();
            for (JsonNode pkg : packages) {
                Map<String, String> pkgInfo = new HashMap<>();
                pkgInfo.put("name", pkg.path("name").asText(""));
                pkgInfo.put("version", pkg.path("versionInfo").asText(""));
                pkgInfo.put("downloadLocation", pkg.path("downloadLocation").asText(""));
                pkgList.add(pkgInfo);
            }
            info.put("packages", pkgList);
        }

        // Extract external refs (including source code reference)
        JsonNode mainPkg = packages.isArray() && packages.size() > 0 ? packages.get(0) : null;
        if (mainPkg != null) {
            JsonNode externalRefs = mainPkg.path("externalRefs");
            if (externalRefs.isArray()) {
                for (JsonNode ref : externalRefs) {
                    String refType = ref.path("referenceType").asText("");
                    if ("vcs".equals(refType) || refType.contains("git")) {
                        info.put("sourceCodeUrl", ref.path("referenceLocator").asText(""));
                    }
                }
            }
        }

        result.put("info", info);
    }

    /**
     * Extract and decode provenance information
     */
    private void extractProvenanceInfo(Map<String, Object> result, JsonNode provenance) {
        Map<String, Object> info = new HashMap<>();

        // SLSA provenance format
        info.put("predicateType", provenance.path("predicateType").asText(""));

        JsonNode predicate = provenance.path("predicate");
        if (!predicate.isMissingNode()) {
            // Builder info
            JsonNode builder = predicate.path("builder");
            if (!builder.isMissingNode()) {
                info.put("builderId", builder.path("id").asText(""));
            }

            // Build type
            info.put("buildType", predicate.path("buildType").asText(""));

            // Invocation (contains config source)
            JsonNode invocation = predicate.path("invocation");
            if (!invocation.isMissingNode()) {
                JsonNode configSource = invocation.path("configSource");
                if (!configSource.isMissingNode()) {
                    info.put("sourceUri", configSource.path("uri").asText(""));
                    info.put("sourceDigest", configSource.path("digest"));
                }
            }

            // Materials (build inputs)
            JsonNode materials = predicate.path("materials");
            if (materials.isArray()) {
                List<Map<String, Object>> materialList = new ArrayList<>();
                for (JsonNode material : materials) {
                    Map<String, Object> mat = new HashMap<>();
                    mat.put("uri", material.path("uri").asText(""));
                    mat.put("digest", material.path("digest"));
                    materialList.add(mat);
                }
                info.put("materials", materialList);
            }

            // Metadata (build timestamps)
            JsonNode metadata = predicate.path("metadata");
            if (!metadata.isMissingNode()) {
                info.put("buildStartedOn", metadata.path("buildStartedOn").asText(""));
                info.put("buildFinishedOn", metadata.path("buildFinishedOn").asText(""));
            }
        }

        result.put("info", info);
    }
}
