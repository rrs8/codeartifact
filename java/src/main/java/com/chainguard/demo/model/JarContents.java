package com.chainguard.demo.model;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * Contents of a JAR file
 */
public class JarContents {
    private String groupId;
    private String artifactId;
    private String version;
    private String jarFile;
    private int totalFiles;
    private long totalSize;
    private List<FileInfo> files;
    private Map<String, Object> tree;
    private String error;

    public JarContents() {
        this.files = new ArrayList<>();
    }

    // Getters and setters
    public String getGroupId() { return groupId; }
    public void setGroupId(String groupId) { this.groupId = groupId; }

    public String getArtifactId() { return artifactId; }
    public void setArtifactId(String artifactId) { this.artifactId = artifactId; }

    public String getVersion() { return version; }
    public void setVersion(String version) { this.version = version; }

    public String getJarFile() { return jarFile; }
    public void setJarFile(String jarFile) { this.jarFile = jarFile; }

    public int getTotalFiles() { return totalFiles; }
    public void setTotalFiles(int totalFiles) { this.totalFiles = totalFiles; }

    public long getTotalSize() { return totalSize; }
    public void setTotalSize(long totalSize) { this.totalSize = totalSize; }

    public List<FileInfo> getFiles() { return files; }
    public void setFiles(List<FileInfo> files) { this.files = files; }

    public Map<String, Object> getTree() { return tree; }
    public void setTree(Map<String, Object> tree) { this.tree = tree; }

    public String getError() { return error; }
    public void setError(String error) { this.error = error; }

    /**
     * Information about a single file within a JAR
     */
    public static class FileInfo {
        private String path;
        private long size;
        private long compressedSize;
        private boolean isDir;

        public FileInfo() {}

        public FileInfo(String path, long size, long compressedSize, boolean isDir) {
            this.path = path;
            this.size = size;
            this.compressedSize = compressedSize;
            this.isDir = isDir;
        }

        public String getPath() { return path; }
        public void setPath(String path) { this.path = path; }

        public long getSize() { return size; }
        public void setSize(long size) { this.size = size; }

        public long getCompressedSize() { return compressedSize; }
        public void setCompressedSize(long compressedSize) { this.compressedSize = compressedSize; }

        public boolean isDir() { return isDir; }
        public void setDir(boolean dir) { isDir = dir; }
    }
}
