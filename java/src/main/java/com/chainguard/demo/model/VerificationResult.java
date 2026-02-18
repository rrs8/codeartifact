package com.chainguard.demo.model;

import java.util.ArrayList;
import java.util.List;

/**
 * Result of chainctl verification across all packages
 */
public class VerificationResult {
    private int verifiedCount;
    private int totalCount;
    private double overallCoverage;
    private double artifactCoverage;
    private String details;
    private List<PackageInfo> packages;
    private String error;

    public VerificationResult() {
        this.packages = new ArrayList<>();
    }

    // Getters and setters
    public int getVerifiedCount() { return verifiedCount; }
    public void setVerifiedCount(int verifiedCount) { this.verifiedCount = verifiedCount; }

    public int getTotalCount() { return totalCount; }
    public void setTotalCount(int totalCount) { this.totalCount = totalCount; }

    public double getOverallCoverage() { return overallCoverage; }
    public void setOverallCoverage(double overallCoverage) { this.overallCoverage = overallCoverage; }

    public double getArtifactCoverage() { return artifactCoverage; }
    public void setArtifactCoverage(double artifactCoverage) { this.artifactCoverage = artifactCoverage; }

    public String getDetails() { return details; }
    public void setDetails(String details) { this.details = details; }

    public List<PackageInfo> getPackages() { return packages; }
    public void setPackages(List<PackageInfo> packages) { this.packages = packages; }

    public String getError() { return error; }
    public void setError(String error) { this.error = error; }

    public void addPackage(PackageInfo pkg) {
        this.packages.add(pkg);
    }
}
