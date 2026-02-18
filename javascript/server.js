/**
 * Node.js Application showcasing Chainguard Libraries for JavaScript
 * Uses ZERO external dependencies - only Node.js built-in modules
 * Requires Node.js 18+ for native fetch support
 */

const http = require('http');
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const fsPromises = require('fs').promises;
const url = require('url');

const PORT = process.env.PORT || 5002;

// Global state for authentication
let authState = {
    authenticated: false,
    authUrl: null,
    authProcess: null,
    error: null
};

// Global state for chainver logs
let chainverLogs = {
    verboseOutput: '',
    lastRun: null
};

/**
 * Simple router implementation
 */
class Router {
    constructor() {
        this.routes = [];
    }

    get(path, handler) {
        this.routes.push({ method: 'GET', path, handler });
    }

    post(path, handler) {
        this.routes.push({ method: 'POST', path, handler });
    }

    match(method, pathname) {
        for (const route of this.routes) {
            if (route.method !== method) continue;

            // Check for exact match
            if (route.path === pathname) {
                return { handler: route.handler, params: {} };
            }

            // Check for parameterized routes like /api/package/:name/:version
            const routeParts = route.path.split('/');
            const pathParts = pathname.split('/');

            if (routeParts.length !== pathParts.length) continue;

            const params = {};
            let match = true;

            for (let i = 0; i < routeParts.length; i++) {
                if (routeParts[i].startsWith(':')) {
                    params[routeParts[i].slice(1)] = decodeURIComponent(pathParts[i]);
                } else if (routeParts[i] !== pathParts[i]) {
                    match = false;
                    break;
                }
            }

            if (match) {
                return { handler: route.handler, params };
            }
        }
        return null;
    }
}

const router = new Router();

/**
 * Parse JSON body from request
 */
async function parseBody(req) {
    return new Promise((resolve, reject) => {
        let body = '';
        req.on('data', chunk => body += chunk);
        req.on('end', () => {
            try {
                resolve(body ? JSON.parse(body) : {});
            } catch (e) {
                resolve({});
            }
        });
        req.on('error', reject);
    });
}

/**
 * Send JSON response
 */
function sendJson(res, data, statusCode = 200) {
    res.writeHead(statusCode, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(data));
}

/**
 * Serve static files from public directory
 */
async function serveStatic(req, res, pathname) {
    const publicDir = path.join(__dirname, 'public');
    let filePath = path.join(publicDir, pathname === '/' ? 'index.html' : pathname);

    // Security: prevent directory traversal
    if (!filePath.startsWith(publicDir)) {
        res.writeHead(403);
        res.end('Forbidden');
        return;
    }

    const mimeTypes = {
        '.html': 'text/html',
        '.js': 'text/javascript',
        '.css': 'text/css',
        '.json': 'application/json',
        '.png': 'image/png',
        '.jpg': 'image/jpeg',
        '.gif': 'image/gif',
        '.svg': 'image/svg+xml',
        '.ico': 'image/x-icon'
    };

    try {
        const stat = await fsPromises.stat(filePath);
        if (stat.isDirectory()) {
            filePath = path.join(filePath, 'index.html');
        }

        const ext = path.extname(filePath).toLowerCase();
        const contentType = mimeTypes[ext] || 'application/octet-stream';
        const content = await fsPromises.readFile(filePath);

        res.writeHead(200, { 'Content-Type': contentType });
        res.end(content);
    } catch (error) {
        if (error.code === 'ENOENT') {
            res.writeHead(404);
            res.end('Not Found');
        } else {
            res.writeHead(500);
            res.end('Internal Server Error');
        }
    }
}

/**
 * Check if chainctl is already authenticated
 */
async function checkAuthStatus() {
    return new Promise((resolve) => {
        const process = spawn('chainctl', ['auth', 'status', '-o', 'json']);
        let stdout = '';

        process.stdout.on('data', (data) => {
            stdout += data.toString();
        });

        process.on('close', (code) => {
            if (code === 0) {
                try {
                    const statusData = JSON.parse(stdout);
                    resolve(!!statusData);
                } catch {
                    resolve(false);
                }
            } else {
                resolve(false);
            }
        });

        setTimeout(() => {
            process.kill();
            resolve(false);
        }, 5000);
    });
}

/**
 * Start headless authentication flow
 */
async function startHeadlessAuth() {
    try {
        if (await checkAuthStatus()) {
            authState.authenticated = true;
            authState.authUrl = null;
            return;
        }

        const process = spawn('chainctl', ['auth', 'login', '--headless']);
        let authUrl = null;

        process.stdout.on('data', (data) => {
            const line = data.toString();
            console.log('chainctl output:', line);

            if (line.includes('Visit this URL') && line.includes('https://')) {
                const urlMatch = line.match(/https:\/\/[^\s]+/);
                if (urlMatch) {
                    authUrl = urlMatch[0];
                    console.log(`Authentication URL generated: ${authUrl}`);
                    authState.authUrl = authUrl;
                    authState.authProcess = process;
                }
            }
        });

        process.on('close', async (code) => {
            if (code === 0) {
                authState.authenticated = true;
                authState.authUrl = null;
                authState.authProcess = null;
                console.log('Authentication completed successfully');
            } else {
                authState.error = 'Authentication process failed';
                authState.authProcess = null;
            }
        });

        if (!authUrl) {
            authState.authProcess = process;
        }

        await new Promise(resolve => setTimeout(resolve, 2000));

        if (!authUrl && !authState.authUrl) {
            authState.error = 'Failed to get authentication URL';
            process.kill();
        }

    } catch (error) {
        console.error('Authentication error:', error);
        authState.error = error.message;
    }
}

/**
 * List installed npm packages (resolved dependencies)
 */
async function runChainver(verbose = false) {
    try {
        console.log('Listing resolved npm packages...');

        const packages = await getInstalledPackages();

        const statusMsg = `Resolved ${packages.length} npm packages.`;

        chainverLogs.verboseOutput = statusMsg;
        chainverLogs.lastRun = new Date().toISOString();

        console.log(`Listed ${packages.length} resolved packages`);

        return {
            packages: packages,
            summary: {
                total: packages.length,
                verified: 0,
                unverified: packages.length
            },
            rawOutput: statusMsg
        };
    } catch (error) {
        console.error('Package listing error:', error);
        return {
            error: error.message,
            packages: [],
            summary: { total: 0, verified: 0, unverified: 0 },
            rawOutput: `Error: ${error.message}`
        };
    }
}

/**
 * Download .tgz tarballs for all installed packages
 */
async function downloadPackageTarballs() {
    const tarballsDir = path.join(__dirname, 'tarballs');

    try {
        if (!fs.existsSync(tarballsDir)) {
            await fsPromises.mkdir(tarballsDir, { recursive: true });
        }

        const packages = await getInstalledPackages();
        console.log(`Found ${packages.length} installed packages`);

        let downloadCount = 0;

        for (const pkg of packages) {
            try {
                const tarballPath = path.join(tarballsDir, `${pkg.name}-${pkg.version}.tgz`);

                if (fs.existsSync(tarballPath)) {
                    downloadCount++;
                    continue;
                }

                console.log(`Downloading ${pkg.name}@${pkg.version}...`);
                const packProc = spawn('npm', ['pack', `${pkg.name}@${pkg.version}`], {
                    cwd: tarballsDir
                });

                await new Promise((resolve, reject) => {
                    packProc.on('close', (code) => {
                        if (code === 0) {
                            downloadCount++;
                            resolve();
                        } else {
                            console.error(`Failed to download ${pkg.name}@${pkg.version}`);
                            resolve();
                        }
                    });
                    packProc.on('error', reject);
                });
            } catch (error) {
                console.error(`Error downloading ${pkg.name}:`, error.message);
            }
        }

        return {
            success: true,
            count: downloadCount,
            dir: tarballsDir
        };
    } catch (error) {
        console.error('Error in downloadPackageTarballs:', error);
        return {
            success: false,
            error: error.message
        };
    }
}

/**
 * Get list of installed npm packages from node_modules
 */
async function getInstalledPackages() {
    const packages = [];
    const nodeModulesPath = path.join(__dirname, 'node_modules');

    try {
        const dirs = fs.readdirSync(nodeModulesPath);

        for (const dir of dirs) {
            if (dir.startsWith('.') || dir.startsWith('@')) continue;

            const packageJsonPath = path.join(nodeModulesPath, dir, 'package.json');
            if (fs.existsSync(packageJsonPath)) {
                try {
                    const packageJson = JSON.parse(fs.readFileSync(packageJsonPath, 'utf-8'));
                    packages.push({
                        name: packageJson.name || dir,
                        version: packageJson.version || 'unknown',
                        verified: false
                    });
                } catch (e) {
                    console.error(`Error reading ${packageJsonPath}:`, e.message);
                }
            }
        }
    } catch (error) {
        console.error('Error reading node_modules:', error.message);
    }

    return packages;
}

/**
 * Fetch SBOM for a package from libraries.cgr.dev
 */
async function fetchSBOM(packageName) {
    try {
        const url = `https://libraries.cgr.dev/npm/${packageName}/sbom.json`;
        const response = await fetch(url, {
            signal: AbortSignal.timeout(10000)
        });
        if (!response.ok) {
            throw new Error(`HTTP ${response.status}`);
        }
        return await response.json();
    } catch (error) {
        throw new Error(`Failed to fetch SBOM: ${error.message}`);
    }
}

/**
 * Fetch provenance for a package from libraries.cgr.dev
 */
async function fetchProvenance(packageName, version) {
    try {
        const url = `https://libraries.cgr.dev/npm/${packageName}/${version}/provenance.json`;
        const response = await fetch(url, {
            signal: AbortSignal.timeout(10000)
        });
        if (!response.ok) {
            throw new Error(`HTTP ${response.status}`);
        }
        return await response.json();
    } catch (error) {
        throw new Error(`Failed to fetch provenance: ${error.message}`);
    }
}

/**
 * Resolve script commands to their actual source files
 */
function resolveScriptCommands(command, packagePath, packageName) {
    const resolved = [];
    const nodeModulesPath = path.join(__dirname, 'node_modules');

    const parts = command.split(/\s*(?:\|\||&&|;|\|)\s*/);

    for (const part of parts) {
        const tokens = part.trim().split(/\s+/);
        if (tokens.length === 0) continue;

        let cmd = tokens[0];

        if (['node', 'npm', 'npx', 'echo', 'exit', 'cd', 'rm', 'mkdir', 'cp', 'mv', 'test', '[', 'true', 'false'].includes(cmd)) {
            if (cmd === 'node' && tokens[1]) {
                const scriptFile = tokens[1];
                const fullPath = path.join(packagePath, scriptFile);
                if (fs.existsSync(fullPath)) {
                    try {
                        const content = fs.readFileSync(fullPath, 'utf8');
                        resolved.push({
                            command: cmd,
                            args: tokens.slice(1).join(' '),
                            binary: scriptFile,
                            source_path: scriptFile,
                            source_content: content.substring(0, 5000),
                            truncated: content.length > 5000
                        });
                    } catch (e) {}
                }
            }
            continue;
        }

        const binPath = path.join(nodeModulesPath, '.bin', cmd);
        let resolvedPath = null;
        let sourceContent = null;

        if (fs.existsSync(binPath)) {
            try {
                const stat = fs.lstatSync(binPath);
                if (stat.isSymbolicLink()) {
                    resolvedPath = fs.readlinkSync(binPath);
                    if (!path.isAbsolute(resolvedPath)) {
                        resolvedPath = path.join(nodeModulesPath, '.bin', resolvedPath);
                    }
                } else {
                    const content = fs.readFileSync(binPath, 'utf8');
                    const match = content.match(/require\(['"]([^'"]+)['"]\)/);
                    if (match) {
                        resolvedPath = path.join(nodeModulesPath, '.bin', match[1]);
                    } else {
                        resolvedPath = binPath;
                    }
                }

                resolvedPath = path.normalize(resolvedPath);

                if (fs.existsSync(resolvedPath)) {
                    sourceContent = fs.readFileSync(resolvedPath, 'utf8');
                }
            } catch (e) {
                console.error('Error resolving binary:', e);
            }
        }

        if (!resolvedPath) {
            const cmdPkgPath = path.join(nodeModulesPath, cmd, 'package.json');
            if (fs.existsSync(cmdPkgPath)) {
                try {
                    const cmdPkg = JSON.parse(fs.readFileSync(cmdPkgPath, 'utf8'));
                    if (cmdPkg.bin) {
                        const binFile = typeof cmdPkg.bin === 'string' ? cmdPkg.bin : cmdPkg.bin[cmd];
                        if (binFile) {
                            resolvedPath = path.join(nodeModulesPath, cmd, binFile);
                            if (fs.existsSync(resolvedPath)) {
                                sourceContent = fs.readFileSync(resolvedPath, 'utf8');
                            }
                        }
                    }
                } catch (e) {}
            }
        }

        let displayPath = resolvedPath;
        if (resolvedPath && resolvedPath.includes('node_modules')) {
            displayPath = resolvedPath.substring(resolvedPath.indexOf('node_modules'));
        }

        resolved.push({
            command: cmd,
            args: tokens.slice(1).join(' '),
            binary: binPath,
            source_path: displayPath,
            source_content: sourceContent ? sourceContent.substring(0, 5000) : null,
            truncated: sourceContent && sourceContent.length > 5000
        });
    }

    return resolved;
}

/**
 * Build hierarchical tree structure from flat file list
 */
function buildFileTree(fileInfo) {
    const tree = {};

    for (const item of fileInfo) {
        const pathParts = item.path.split('/');
        let current = tree;

        for (let i = 0; i < pathParts.length; i++) {
            const part = pathParts[i];

            if (i === pathParts.length - 1) {
                if (part) {
                    current[part] = {
                        type: item.is_dir ? 'dir' : 'file',
                        size: item.size,
                        path: item.path
                    };
                }
            } else {
                if (!current[part]) {
                    current[part] = { type: 'dir', children: {} };
                } else if (!current[part].children) {
                    current[part].children = {};
                }
                current = current[part].children;
            }
        }
    }

    return tree;
}

// Define routes

/**
 * Authentication status endpoint
 */
router.get('/api/auth/status', async (req, res) => {
    sendJson(res, {
        authenticated: true,
        auth_url: null,
        error: null
    });
});

/**
 * Run chainver verification
 */
router.get('/api/chainver', async (req, res) => {
    try {
        const result = await runChainver(false);
        sendJson(res, result);
    } catch (error) {
        console.error('Chainver error:', error);
        sendJson(res, { error: error.message }, 500);
    }
});

/**
 * Get chainver logs
 */
router.get('/api/chainver/logs', async (req, res) => {
    sendJson(res, {
        output: chainverLogs.verboseOutput,
        lastRun: chainverLogs.lastRun
    });
});

/**
 * Run verbose chainver
 */
router.get('/api/chainver/verbose', async (req, res) => {
    try {
        const result = await runChainver(true);
        sendJson(res, result);
    } catch (error) {
        console.error('Chainver verbose error:', error);
        sendJson(res, { error: error.message }, 500);
    }
});

/**
 * Get package SBOM
 */
router.get('/api/sbom/:package', async (req, res, params) => {
    try {
        const sbom = await fetchSBOM(params.package);
        sendJson(res, sbom);
    } catch (error) {
        console.error('SBOM fetch error:', error);
        sendJson(res, { error: error.message }, 404);
    }
});

/**
 * Get package provenance from npm registry
 * Note: Nexus doesn't support the attestations API, so we always go direct to npmjs.org
 */
router.post('/api/provenance/:package/:version', async (req, res, params) => {
    try {
        const packageName = params.package;
        const version = params.version;

        // Always use registry.npmjs.org for attestations - Nexus doesn't proxy this endpoint
        const attestationsUrl = `https://registry.npmjs.org/-/npm/v1/attestations/${packageName}@${version}`;
        console.log(`Fetching attestations from: ${attestationsUrl}`);

        const response = await fetch(attestationsUrl, {
            headers: { 'Accept': 'application/json' },
            signal: AbortSignal.timeout(10000)
        });

        if (!response.ok) {
            if (response.status === 404) {
                return sendJson(res, {
                    hasProvenance: false,
                    message: 'No attestations found - package may not have provenance enabled'
                });
            }
            throw new Error(`HTTP ${response.status}`);
        }

        const data = await response.json();

        if (!data || !data.attestations || data.attestations.length === 0) {
            return sendJson(res, {
                hasProvenance: false,
                message: 'No provenance attestations found for this package'
            });
        }

        // Parse all attestations
        const parsedAttestations = [];

        for (const attestation of data.attestations) {
            try {
                const bundle = attestation.bundle;
                const attestationType = attestation.predicateType;

                let parsedAttestation = {
                    type: attestationType,
                    bundle: bundle
                };

                // Parse the DSSE envelope payload
                if (bundle.dsseEnvelope && bundle.dsseEnvelope.payload) {
                    const payload = JSON.parse(Buffer.from(bundle.dsseEnvelope.payload, 'base64').toString('utf-8'));
                    parsedAttestation.payload = payload;
                    parsedAttestation.subject = payload.subject;
                    parsedAttestation.predicate = payload.predicate;
                }

                // Extract verification material
                if (bundle.verificationMaterial) {
                    parsedAttestation.verificationMaterial = {
                        certificate: bundle.verificationMaterial.x509CertificateChain || bundle.verificationMaterial.certificate,
                        tlogEntries: bundle.verificationMaterial.tlogEntries
                    };
                }

                // SLSA-specific parsing
                if (attestationType.includes('slsa.dev/provenance')) {
                    if (parsedAttestation.predicate) {
                        parsedAttestation.slsa = {
                            buildType: parsedAttestation.predicate.buildType || parsedAttestation.predicate.buildDefinition?.buildType,
                            builder: parsedAttestation.predicate.buildDefinition?.runDetails?.builder?.id || parsedAttestation.predicate.builder?.id,
                            invocation: parsedAttestation.predicate.buildDefinition?.runDetails?.metadata?.invocationId || parsedAttestation.predicate.runDetails?.metadata?.invocationId || parsedAttestation.predicate.invocation,
                            buildDefinition: parsedAttestation.predicate.buildDefinition
                        };

                        const resolvedDeps = parsedAttestation.predicate.buildDefinition?.resolvedDependencies;
                        if (resolvedDeps && resolvedDeps.length > 0) {
                            const sourceMaterial = resolvedDeps[0];
                            parsedAttestation.slsa.sourceRepo = sourceMaterial.uri;
                            parsedAttestation.slsa.sourceDigest = sourceMaterial.digest;
                        }

                        const workflow = parsedAttestation.predicate.buildDefinition?.externalParameters?.workflow;
                        if (workflow) {
                            parsedAttestation.slsa.workflow = {
                                path: workflow.path,
                                ref: workflow.ref,
                                repository: workflow.repository
                            };
                        }

                        const github = parsedAttestation.predicate.buildDefinition?.internalParameters?.github;
                        if (github) {
                            parsedAttestation.slsa.github = {
                                eventName: github.event_name,
                                repositoryId: github.repository_id,
                                repositoryOwnerId: github.repository_owner_id
                            };
                        }
                    }
                }

                // npm publish attestation parsing
                if (attestationType.includes('github.com/npm/attestation')) {
                    if (parsedAttestation.predicate) {
                        parsedAttestation.npmPublish = {
                            name: parsedAttestation.predicate.name,
                            version: parsedAttestation.predicate.version,
                            registry: parsedAttestation.predicate.registry
                        };
                    }
                }

                parsedAttestations.push(parsedAttestation);
            } catch (parseError) {
                console.error('Error parsing attestation:', parseError);
            }
        }

        // Find SLSA and npm publish attestations
        const slsaAttestation = parsedAttestations.find(a => a.type.includes('slsa.dev/provenance'));
        const npmPublishAttestation = parsedAttestations.find(a => a.type.includes('github.com/npm/attestation'));

        if (!slsaAttestation) {
            return sendJson(res, {
                hasProvenance: false,
                message: 'No SLSA provenance attestation found',
                attestations: parsedAttestations.map(a => a.type)
            });
        }

        // Build response with parsed data
        let provenanceData = {
            hasProvenance: true,
            attestations: parsedAttestations,
            predicateType: slsaAttestation.type,
            bundle: slsaAttestation.bundle,
            subject: slsaAttestation.subject,
            predicate: slsaAttestation.predicate
        };

        if (slsaAttestation.slsa) {
            provenanceData.builder = slsaAttestation.slsa.builder;
            provenanceData.buildType = slsaAttestation.slsa.buildType;
            provenanceData.sourceRepo = slsaAttestation.slsa.sourceRepo;
            provenanceData.sourceDigest = slsaAttestation.slsa.sourceDigest;
            provenanceData.invocation = slsaAttestation.slsa.invocation;
            provenanceData.workflow = slsaAttestation.slsa.workflow;
            provenanceData.github = slsaAttestation.slsa.github;
        }

        if (npmPublishAttestation) {
            provenanceData.npmPublish = npmPublishAttestation.npmPublish;
        }

        sendJson(res, provenanceData);
    } catch (error) {
        console.error('Provenance fetch error:', error);
        sendJson(res, {
            error: error.message,
            hasProvenance: false
        }, 500);
    }
});

/**
 * Get package contents
 */
router.get('/api/package-contents/:package/:version', async (req, res, params) => {
    try {
        const packageName = params.package;
        const version = params.version;
        const packagePath = path.join(__dirname, 'node_modules', packageName);

        if (!fs.existsSync(packagePath)) {
            return sendJson(res, { error: `Package ${packageName} not found in node_modules` }, 404);
        }

        const fileList = [];
        let totalSize = 0;

        function walkDir(dir, relativePath = '') {
            const entries = fs.readdirSync(dir, { withFileTypes: true });

            for (const entry of entries) {
                const fullPath = path.join(dir, entry.name);
                const relPath = relativePath ? `${relativePath}/${entry.name}` : entry.name;

                if (entry.isDirectory()) {
                    fileList.push({
                        path: relPath + '/',
                        size: 0,
                        is_dir: true
                    });
                    walkDir(fullPath, relPath);
                } else {
                    const stats = fs.statSync(fullPath);
                    fileList.push({
                        path: relPath,
                        size: stats.size,
                        is_dir: false
                    });
                    totalSize += stats.size;
                }
            }
        }

        walkDir(packagePath);

        const tree = buildFileTree(fileList);

        // Extract lifecycle scripts
        let lifecycleScripts = {};
        const packageJsonPath = path.join(packagePath, 'package.json');
        if (fs.existsSync(packageJsonPath)) {
            try {
                const pkgJson = JSON.parse(fs.readFileSync(packageJsonPath, 'utf8'));
                const scriptNames = [
                    'preinstall', 'install', 'postinstall',
                    'preuninstall', 'uninstall', 'postuninstall',
                    'prepublish', 'preprepare', 'prepare', 'postprepare',
                    'prepack', 'postpack'
                ];
                if (pkgJson.scripts) {
                    for (const scriptName of scriptNames) {
                        if (pkgJson.scripts[scriptName]) {
                            const scriptCommand = pkgJson.scripts[scriptName];
                            const resolvedScripts = resolveScriptCommands(scriptCommand, packagePath, packageName);
                            lifecycleScripts[scriptName] = {
                                command: scriptCommand,
                                resolved: resolvedScripts
                            };
                        }
                    }
                }
            } catch (e) {
                console.error('Error reading package.json for lifecycle scripts:', e);
            }
        }

        sendJson(res, {
            package: packageName,
            version: version,
            total_files: fileList.length,
            total_size: totalSize,
            files: fileList,
            tree: tree,
            lifecycle_scripts: lifecycleScripts
        });
    } catch (error) {
        console.error('Package contents error:', error);
        sendJson(res, { error: error.message }, 500);
    }
});

/**
 * Get package.json contents
 */
router.get('/api/package-json', async (req, res) => {
    try {
        const packageJson = await fsPromises.readFile(path.join(__dirname, 'package.json'), 'utf-8');
        sendJson(res, JSON.parse(packageJson));
    } catch (error) {
        console.error('package.json read error:', error);
        sendJson(res, { error: error.message }, 500);
    }
});

/**
 * Create HTTP server
 */
const server = http.createServer(async (req, res) => {
    const parsedUrl = url.parse(req.url, true);
    const pathname = parsedUrl.pathname;
    const method = req.method;

    // Try to match a route
    const match = router.match(method, pathname);

    if (match) {
        try {
            if (method === 'POST' || method === 'PUT' || method === 'PATCH') {
                req.body = await parseBody(req);
            }
            await match.handler(req, res, match.params);
        } catch (error) {
            console.error('Route error:', error);
            sendJson(res, { error: error.message }, 500);
        }
    } else if (method === 'GET') {
        // Serve static files for non-API routes
        await serveStatic(req, res, pathname);
    } else {
        res.writeHead(404);
        res.end('Not Found');
    }
});

// Start server
server.listen(PORT, () => {
    console.log(`Chainguard Libraries JavaScript Demo running on http://localhost:${PORT}`);
    console.log('Using ZERO external dependencies - pure Node.js!');
});