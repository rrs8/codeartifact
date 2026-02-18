package com.chainguard.demo.model;

/**
 * Progress information for ongoing verification
 */
public class VerificationProgress {
    private int completed;
    private int total;
    private String status; // idle, running, complete

    public VerificationProgress() {
        this.status = "idle";
    }

    public VerificationProgress(int completed, int total, String status) {
        this.completed = completed;
        this.total = total;
        this.status = status;
    }

    public int getCompleted() { return completed; }
    public void setCompleted(int completed) { this.completed = completed; }

    public int getTotal() { return total; }
    public void setTotal(int total) { this.total = total; }

    public String getStatus() { return status; }
    public void setStatus(String status) { this.status = status; }
}
