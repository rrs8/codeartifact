package com.chainguard.demo.model;

/**
 * Information about a single Maven package/JAR
 */
public class PackageInfo {
    private String groupId;
    private String artifactId;
    private String version;
    private String filename;
    private boolean verified;
    private String details;
    private String verificationMethod;
    private String rekorUrl;

    public PackageInfo() {}

    public PackageInfo(String groupId, String artifactId, String version) {
        this.groupId = groupId;
        this.artifactId = artifactId;
        this.version = version;
    }

    // Getters and setters
    public String getGroupId() { return groupId; }
    public void setGroupId(String groupId) { this.groupId = groupId; }

    public String getArtifactId() { return artifactId; }
    public void setArtifactId(String artifactId) { this.artifactId = artifactId; }

    public String getVersion() { return version; }
    public void setVersion(String version) { this.version = version; }

    public String getFilename() { return filename; }
    public void setFilename(String filename) { this.filename = filename; }

    public boolean isVerified() { return verified; }
    public void setVerified(boolean verified) { this.verified = verified; }

    public String getDetails() { return details; }
    public void setDetails(String details) { this.details = details; }

    public String getVerificationMethod() { return verificationMethod; }
    public void setVerificationMethod(String verificationMethod) { this.verificationMethod = verificationMethod; }

    public String getRekorUrl() { return rekorUrl; }
    public void setRekorUrl(String rekorUrl) { this.rekorUrl = rekorUrl; }

    /**
     * Get the Maven coordinate string (groupId:artifactId:version)
     */
    public String getCoordinates() {
        String g = groupId != null ? groupId : "";
        String a = artifactId != null ? artifactId : "";
        String v = version != null ? version : "";
        return String.format("%s:%s:%s", g, a, v);
    }

    /**
     * Get the path format for Chainguard Libraries API
     * e.g., org/apache/commons/commons-lang3/3.14.0
     */
    public String getLibrariesPath() {
        String g = groupId != null ? groupId.replace('.', '/') : "";
        String a = artifactId != null ? artifactId : "";
        String v = version != null ? version : "";
        return String.format("%s/%s/%s", g, a, v);
    }
}
