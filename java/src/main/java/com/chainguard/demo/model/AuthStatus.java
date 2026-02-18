package com.chainguard.demo.model;

/**
 * Authentication status for chainctl
 */
public class AuthStatus {
    private boolean authenticated;
    private String authUrl;
    private String error;

    public AuthStatus() {}

    public AuthStatus(boolean authenticated) {
        this.authenticated = authenticated;
    }

    public boolean isAuthenticated() { return authenticated; }
    public void setAuthenticated(boolean authenticated) { this.authenticated = authenticated; }

    public String getAuthUrl() { return authUrl; }
    public void setAuthUrl(String authUrl) { this.authUrl = authUrl; }

    public String getError() { return error; }
    public void setError(String error) { this.error = error; }
}
