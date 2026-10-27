import Foundation

// The same test server as SourceDeckCoreTests/CredentialSandbox.swift:
// test targets can't share a file, and the app's sign-in flow needs a remote
// that asks for an account.

/// Bare repositories served over smart HTTP behind Basic auth, by
/// `git http-backend` under a small Python server on 127.0.0.1 — a remote
/// that asks for an account the way GitHub or Gitea does.
final class AuthHTTPServer: @unchecked Sendable {
    static let python = "/usr/bin/python3"
    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: python) }

    let port: Int
    private let process = Process()

    /// - Parameter root: the folder of bare repositories, served at "/<name>".
    init(root: URL, username: String, password: String) throws {
        let script = root.deletingLastPathComponent().appendingPathComponent("auth-http-server.py")
        try Data(Self.script.utf8).write(to: script)
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: Self.python)
        process.arguments = ["-I", script.path, root.path, username, password]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        var line = Data()
        while !line.contains(UInt8(ascii: "\n")) {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            line.append(chunk)
        }
        port = Int(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    deinit {
        process.terminate()
        process.waitUntilExit()
    }

    func url(_ repository: String) -> String { "http://127.0.0.1:\(port)/\(repository)" }

    /// Answers 401 without the right Basic auth; otherwise runs
    /// `git http-backend` as CGI. REMOTE_USER lets it accept pushes.
    private static let script = #"""
    import base64, http.server, os, subprocess, sys
    root, user, password = sys.argv[1], sys.argv[2], sys.argv[3]
    expected = "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def handle_one(self):
            if self.headers.get("Authorization") != expected:
                self.send_response(401)
                self.send_header("WWW-Authenticate", 'Basic realm="test"')
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
                body = b""
                while True:
                    size = int(self.rfile.readline().strip(), 16)
                    if size == 0:
                        self.rfile.readline()
                        break
                    body += self.rfile.read(size)
                    self.rfile.readline()
            else:
                body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
            path, _, query = self.path.partition("?")
            env = {"GIT_PROJECT_ROOT": root, "GIT_HTTP_EXPORT_ALL": "1", "PATH_INFO": path, "QUERY_STRING": query,
                   "REQUEST_METHOD": self.command, "CONTENT_TYPE": self.headers.get("Content-Type", ""),
                   "CONTENT_LENGTH": str(len(body)), "REMOTE_USER": user, "REMOTE_ADDR": "127.0.0.1",
                   "HTTP_CONTENT_ENCODING": self.headers.get("Content-Encoding", ""), "PATH": os.environ["PATH"],
                   "GIT_CONFIG_NOSYSTEM": "1", "HOME": root}
            out = subprocess.run(["git", "http-backend"], input=body, env=env, capture_output=True).stdout
            head, _, payload = out.partition(b"\r\n\r\n")
            status, headers = 200, []
            for line in head.split(b"\r\n"):
                name, _, value = line.decode().partition(":")
                if name.lower() == "status":
                    status = int(value.strip().split()[0])
                elif name:
                    headers.append((name, value.strip()))
            self.send_response(status)
            for name, value in headers:
                self.send_header(name, value)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        do_GET = do_POST = handle_one

    server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_address[1], flush=True)
    server.serve_forever()
    """#
}
