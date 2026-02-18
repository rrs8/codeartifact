package com.chainguard.demo;

import com.chainguard.demo.service.ChainctlService;
import com.chainguard.demo.service.SbomService;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.*;
import java.net.InetSocketAddress;
import java.nio.file.*;
import java.util.*;
import java.util.stream.Collectors;

/**
 * Chainguard Libraries Java Demo Application
 * Uses Java's built-in HTTP server for minimal dependencies.
 * Runs on port 5001.
 */
public class DemoApplication {

    private static final ChainctlService chainctlService = new ChainctlService();
    private static final SbomService sbomService = new SbomService();
    private static final ObjectMapper objectMapper = new ObjectMapper();

    public static void main(String[] args) throws IOException {
        HttpServer server = HttpServer.create(new InetSocketAddress(5001), 0);

        // Health check
        server.createContext("/health", exchange -> {
            sendJson(exchange, Map.of("status", "healthy"));
        });

        // Get list of dependencies
        server.createContext("/api/dependencies", exchange -> {
            try {
                Path libsPath = Paths.get("/app/libs");
                if (!Files.exists(libsPath)) {
                    sendJson(exchange, Collections.emptyList());
                    return;
                }
                List<String> jars = Files.list(libsPath)
                    .filter(p -> p.toString().endsWith(".jar"))
                    .map(p -> p.getFileName().toString())
                    .sorted()
                    .collect(Collectors.toList());
                sendJson(exchange, jars);
            } catch (Exception e) {
                sendJson(exchange, Collections.emptyList());
            }
        });

        // Get pom.xml content
        server.createContext("/api/pom", exchange -> {
            try {
                Path pomPath = Paths.get("/app/pom.xml");
                if (!Files.exists(pomPath)) {
                    // Try classpath for local development
                    InputStream is = DemoApplication.class.getResourceAsStream("/pom.xml");
                    if (is != null) {
                        String content = new String(is.readAllBytes());
                        is.close();
                        sendJson(exchange, Map.of("content", content));
                        return;
                    }
                    sendJson(exchange, Map.of("error", "pom.xml not found"));
                    return;
                }
                String content = Files.readString(pomPath);
                sendJson(exchange, Map.of("content", content));
            } catch (Exception e) {
                sendJson(exchange, Map.of("error", e.getMessage()));
            }
        });

        // Authentication status
        server.createContext("/api/auth/status", exchange -> {
            sendJson(exchange, chainctlService.checkAuthStatus());
        });

        // Run chainctl verification
        server.createContext("/api/chainctl/progress", exchange -> {
            sendJson(exchange, chainctlService.getProgress());
        });

        server.createContext("/api/chainctl/logs", exchange -> {
            sendJson(exchange, chainctlService.getLogs());
        });

        server.createContext("/api/chainctl", exchange -> {
            String path = exchange.getRequestURI().getPath();
            // Avoid matching /api/chainctl/progress and /api/chainctl/logs
            if (!path.equals("/api/chainctl")) {
                exchange.sendResponseHeaders(404, -1);
                return;
            }
            try {
                sendJson(exchange, chainctlService.getVerificationResults());
            } catch (Exception e) {
                sendJson(exchange, Map.of("error", e.getMessage()));
            }
        });

        // Get JAR file contents - /api/jar-contents/{artifactId}/{version}
        server.createContext("/api/jar-contents/", exchange -> {
            String[] parts = exchange.getRequestURI().getPath().split("/");
            if (parts.length >= 5) {
                sendJson(exchange, chainctlService.getJarContents(parts[3], parts[4]));
            } else {
                sendJson(exchange, Map.of("error", "Invalid path"));
            }
        });

        // Get SHA256 hash - /api/rekor-hash/{artifactId}/{version}
        server.createContext("/api/rekor-hash/", exchange -> {
            String[] parts = exchange.getRequestURI().getPath().split("/");
            if (parts.length >= 5) {
                Map<String, String> result = chainctlService.getJarHash(parts[3], parts[4]);
                sendJson(exchange, result != null ? result : Map.of("error", "JAR file not found"));
            } else {
                sendJson(exchange, Map.of("error", "Invalid path"));
            }
        });

        // Get SBOM - /api/sbom/{groupId}/{artifactId}/{version} or /api/sbom/{artifactId}/{version}
        server.createContext("/api/sbom/", exchange -> {
            String[] parts = exchange.getRequestURI().getPath().split("/");
            if (parts.length >= 6) {
                String groupId = parts[3].replace('-', '.');
                sendJson(exchange, sbomService.getSbom(groupId, parts[4], parts[5]));
            } else if (parts.length >= 5) {
                sendJson(exchange, sbomService.getSbom(null, parts[3], parts[4]));
            } else {
                sendJson(exchange, Map.of("error", "Invalid path"));
            }
        });

        // Get provenance - /api/provenance/{groupId}/{artifactId}/{version} or /api/provenance/{artifactId}/{version}
        server.createContext("/api/provenance/", exchange -> {
            String[] parts = exchange.getRequestURI().getPath().split("/");
            if (parts.length >= 6) {
                String groupId = parts[3].replace('-', '.');
                sendJson(exchange, sbomService.getProvenance(groupId, parts[4], parts[5]));
            } else if (parts.length >= 5) {
                sendJson(exchange, sbomService.getProvenance(null, parts[3], parts[4]));
            } else {
                sendJson(exchange, Map.of("error", "Invalid path"));
            }
        });

        // Serve static files
        server.createContext("/", exchange -> {
            String path = exchange.getRequestURI().getPath();
            if (path.equals("/")) {
                path = "/index.html";
            }

            // Try classpath first, then filesystem
            InputStream is = DemoApplication.class.getResourceAsStream("/static" + path);
            if (is == null) {
                // Try /app/static for Docker
                Path filePath = Paths.get("/app/static" + path);
                if (Files.exists(filePath)) {
                    is = Files.newInputStream(filePath);
                }
            }

            if (is != null) {
                byte[] content = is.readAllBytes();
                is.close();

                String contentType = "text/plain";
                if (path.endsWith(".html")) contentType = "text/html";
                else if (path.endsWith(".css")) contentType = "text/css";
                else if (path.endsWith(".js")) contentType = "application/javascript";
                else if (path.endsWith(".json")) contentType = "application/json";
                else if (path.endsWith(".svg")) contentType = "image/svg+xml";
                else if (path.endsWith(".png")) contentType = "image/png";

                exchange.getResponseHeaders().set("Content-Type", contentType);
                exchange.sendResponseHeaders(200, content.length);
                exchange.getResponseBody().write(content);
                exchange.getResponseBody().close();
            } else {
                exchange.sendResponseHeaders(404, -1);
            }
        });

        server.setExecutor(null);
        server.start();
        System.out.println("Java Libraries Demo running at http://localhost:5001");
    }

    private static void sendJson(HttpExchange exchange, Object data) throws IOException {
        byte[] response = objectMapper.writeValueAsBytes(data);
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        exchange.sendResponseHeaders(200, response.length);
        exchange.getResponseBody().write(response);
        exchange.getResponseBody().close();
    }
}
