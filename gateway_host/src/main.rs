use anyhow::{anyhow, Context, Result};
use once_cell::sync::Lazy;
use sha2::{Digest, Sha256};
use std::env;
use std::io::{Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};
use url::Url;
use uuid::Uuid;

const MAX_HEADER_BYTES: usize = 64 * 1024;
const MAX_REQ_BODY_BYTES: usize = 2 * 1024 * 1024;
const MAX_RESP_BYTES: usize = 10 * 1024 * 1024;
const IO_TIMEOUT: Duration = Duration::from_secs(5);
const GATEWAY_VARIANT: &str = "wasm-host";

static COUNTER: Lazy<AtomicU64> = Lazy::new(|| AtomicU64::new(0));

fn cpu_heavy(iters: u64) -> String {
    let mut hash = [0u8; 32];

    for i in 0..iters {
        let mut hasher = Sha256::new();
        hasher.update(hash);
        hasher.update(i.to_le_bytes());
        hash = hasher.finalize().into();
    }

    hex::encode(hash)
}

// simple query parser for /compute?iters=123
fn query_param(path: &str, key: &str) -> Option<String> {
    let q = path.splitn(2, '?').nth(1)?;
    for pair in q.split('&') {
        let mut it = pair.splitn(2, '=');
        let k = it.next().unwrap_or("");
        let v = it.next().unwrap_or("");
        if k == key {
            return Some(v.to_string());
        }
    }
    None
}

fn main() -> Result<()> {
    env_logger::init();

    let listen = env::var("LISTEN").unwrap_or_else(|_| "0.0.0.0:8080".to_string());
    let upstream_url =
        env::var("UPSTREAM_URL").unwrap_or_else(|_| "http://127.0.0.1:18080".to_string());
    let wasm_module_path =
        env::var("WASM_MODULE_PATH").unwrap_or_else(|_| "./gateway_logic.wasm".to_string());
    let wasm_runtime = env::var("WASM_RUNTIME").unwrap_or_else(|_| "wasmedge".to_string());
    if wasm_runtime != "wasmedge" && wasm_runtime != "wasmtime" {
        return Err(anyhow!(
            "invalid WASM_RUNTIME={wasm_runtime} (expected: wasmedge|wasmtime)"
        ));
    }

    let upstream = parse_upstream(&upstream_url)?;
    let listener = TcpListener::bind(&listen).with_context(|| format!("bind LISTEN={listen}"))?;

    eprintln!("[wasm-host] listening on http://{listen}");
    eprintln!("[wasm-host] forwarding to {upstream_url}");
    eprintln!("[wasm-host] wasm module: {wasm_module_path}");
    eprintln!("[wasm-host] wasm runtime: {wasm_runtime}");

    for incoming in listener.incoming() {
        match incoming {
            Ok(mut client) => {
                if let Err(e) =
                    handle_client(&mut client, &upstream, &wasm_module_path, &wasm_runtime)
                {
                    eprintln!("[wasm-host] client error: {e:#}");
                }
            }
            Err(e) => eprintln!("[wasm-host] accept error: {e}"),
        }
    }

    Ok(())
}

#[derive(Clone, Debug)]
struct Upstream {
    host: String,
    port: u16,
    base_path: String,
    raw_url: String,
}

fn parse_upstream(s: &str) -> Result<Upstream> {
    let url = Url::parse(s).with_context(|| format!("invalid UPSTREAM_URL={s}"))?;
    if url.scheme() != "http" {
        return Err(anyhow!(
            "only http upstream supported (got scheme {})",
            url.scheme()
        ));
    }
    let host = url
        .host_str()
        .ok_or_else(|| anyhow!("UPSTREAM_URL missing host"))?
        .to_string();
    let port = url
        .port_or_known_default()
        .ok_or_else(|| anyhow!("UPSTREAM_URL missing port"))?;
    let base_path = url.path().trim_end_matches('/').to_string();
    Ok(Upstream {
        host,
        port,
        base_path,
        raw_url: s.to_string(),
    })
}

fn handle_client(
    client: &mut TcpStream,
    upstream: &Upstream,
    wasm_module_path: &str,
    wasm_runtime: &str,
) -> Result<()> {
    client.set_read_timeout(Some(IO_TIMEOUT)).ok();
    client.set_write_timeout(Some(IO_TIMEOUT)).ok();

    let req_id = Uuid::new_v4();
    let start = Instant::now();

    let (head_bytes, body_bytes) = read_http_request(client)?;
    let req = parse_request_head(&head_bytes)?;

    if req.method == "GET" && req.path == "/health" {
        let resp = build_response("HTTP/1.1 200 OK", b"OK", "health", Some("text/plain"), &[]);
        client.write_all(&resp).ok();
        client.flush().ok();
        client.shutdown(Shutdown::Both).ok();
        return Ok(());
    }

    if req.method == "GET" && (req.path == "/" || req.path.starts_with("/?")) {
        let body = wasm_transform(wasm_runtime, wasm_module_path, b"hello")
            .context("wasm transform failed for / workload")?;
        let resp = build_response("HTTP/1.1 200 OK", &body, "hello", Some("text/plain"), &[]);
        client.write_all(&resp)?;
        client.flush().ok();
        client.shutdown(std::net::Shutdown::Both).ok();
        return Ok(());
    }

    if req.method == "GET" && req.path.starts_with("/compute") {
        let iters = query_param(&req.path, "iters")
            .and_then(|v| v.parse::<u64>().ok())
            .unwrap_or(50_000);

        let result = cpu_heavy(iters);
        let body = wasm_transform(wasm_runtime, wasm_module_path, result.as_bytes())
            .context("wasm transform failed for /compute workload")?;
        let resp = build_response("HTTP/1.1 200 OK", &body, "compute", Some("text/plain"), &[]);
        client.write_all(&resp)?;
        client.flush().ok();
        client.shutdown(std::net::Shutdown::Both).ok();
        return Ok(());
    }

    if req.method == "GET" && req.path.starts_with("/state") {
        let value = COUNTER.fetch_add(1, Ordering::SeqCst);
        let body_str = value.to_string();
        let body = wasm_transform(wasm_runtime, wasm_module_path, body_str.as_bytes())
            .context("wasm transform failed for /state workload")?;
        let resp = build_response("HTTP/1.1 200 OK", &body, "state", Some("text/plain"), &[]);
        client.write_all(&resp)?;
        client.flush().ok();
        client.shutdown(std::net::Shutdown::Both).ok();
        return Ok(());
    }

    // Forward to upstream
    let mut upstream_stream = TcpStream::connect((&*upstream.host, upstream.port))
        .with_context(|| format!("connect upstream {}:{}", upstream.host, upstream.port))?;
    upstream_stream.set_read_timeout(Some(IO_TIMEOUT)).ok();
    upstream_stream.set_write_timeout(Some(IO_TIMEOUT)).ok();

    let forwarded = build_forwarded_request(&req, &head_bytes, &body_bytes, upstream)?;
    upstream_stream.write_all(&forwarded)?;
    upstream_stream.flush()?;

    let resp_bytes = read_all_response(&mut upstream_stream)?;
    let (resp_head, resp_body) = split_http_response(&resp_bytes)?;
    let upstream_status = parse_status_code_from_head(&resp_head)?;
    let upstream_status_str = upstream_status.to_string();
    let transformed_body = wasm_transform(wasm_runtime, wasm_module_path, &resp_body)
        .context("wasm transform failed for proxy workload")?;
    let proxy_headers = vec![
        ("X-Upstream-Url", upstream.raw_url.as_str()),
        ("X-Upstream-Status", upstream_status_str.as_str()),
    ];
    let new_resp = rebuild_response_with_extra_headers(
        &resp_head,
        &transformed_body,
        "proxy",
        &proxy_headers,
    )?;

    client.write_all(&new_resp)?;
    client.flush().ok();
    client.shutdown(Shutdown::Both).ok();

    let elapsed = start.elapsed().as_millis();
    eprintln!(
        "[wasm-host] req_id={} {} {} -> {} bytes, {} ms",
        req_id,
        req.method,
        req.path,
        new_resp.len(),
        elapsed
    );

    Ok(())
}

#[derive(Debug)]
struct RequestLine {
    method: String,
    path: String,
    version: String,
    content_length: usize,
}

/// Reads request head until CRLFCRLF, then reads body if Content-Length is present.
/// Does NOT support chunked transfer encoding.
fn read_http_request(stream: &mut TcpStream) -> Result<(Vec<u8>, Vec<u8>)> {
    let mut buf = Vec::<u8>::new();
    let mut tmp = [0u8; 4096];

    // Read until headers end
    loop {
        let n = stream.read(&mut tmp).context("read from client")?;
        if n == 0 {
            return Err(anyhow!("client closed before request complete"));
        }
        buf.extend_from_slice(&tmp[..n]);

        if buf.len() > MAX_HEADER_BYTES {
            return Err(anyhow!("request headers too large"));
        }
        if find_double_crlf(&buf).is_some() {
            break;
        }
    }

    let header_end = find_double_crlf(&buf).ok_or_else(|| anyhow!("malformed headers"))?;
    let head = buf[..header_end].to_vec();
    let mut remainder = buf[header_end + 4..].to_vec();

    let req = parse_request_head(&head)?;
    let mut body = Vec::<u8>::new();

    if req.content_length > 0 {
        if req.content_length > MAX_REQ_BODY_BYTES {
            return Err(anyhow!(
                "request body too large (Content-Length {})",
                req.content_length
            ));
        }

        body.extend_from_slice(&remainder);
        remainder.clear();

        while body.len() < req.content_length {
            let n = stream.read(&mut tmp).context("read request body")?;
            if n == 0 {
                return Err(anyhow!(
                    "client closed during body read (got {}, expected {})",
                    body.len(),
                    req.content_length
                ));
            }
            body.extend_from_slice(&tmp[..n]);
            if body.len() > req.content_length {
                body.truncate(req.content_length);
                break;
            }
        }
    }

    Ok((head, body))
}

fn parse_request_head(head: &[u8]) -> Result<RequestLine> {
    let s = std::str::from_utf8(head).context("headers not valid UTF-8")?;
    let mut lines = s.split("\r\n");

    let request_line = lines.next().ok_or_else(|| anyhow!("empty request"))?;
    let mut parts = request_line.split_whitespace();
    let method = parts
        .next()
        .ok_or_else(|| anyhow!("missing method"))?
        .to_string();
    let path = parts
        .next()
        .ok_or_else(|| anyhow!("missing path"))?
        .to_string();
    let version = parts
        .next()
        .ok_or_else(|| anyhow!("missing version"))?
        .to_string();

    let mut content_length = 0usize;
    for line in lines {
        let lower = line.to_ascii_lowercase();
        if let Some(rest) = lower.strip_prefix("content-length:") {
            content_length = rest
                .trim()
                .parse::<usize>()
                .context("invalid Content-Length")?;
        }
    }

    Ok(RequestLine {
        method,
        path,
        version,
        content_length,
    })
}

/// Rewrites request line to respect upstream base_path.
/// Rewrites Host.
/// Forces Connection: close.
fn build_forwarded_request(
    req: &RequestLine,
    original_head: &[u8],
    body: &[u8],
    upstream: &Upstream,
) -> Result<Vec<u8>> {
    let original = std::str::from_utf8(original_head).context("original headers not UTF-8")?;

    let forwarded_path = if upstream.base_path.is_empty() || upstream.base_path == "/" {
        req.path.clone()
    } else {
        let bp = upstream.base_path.trim_end_matches('/');
        let rp = req.path.trim_start_matches('/');
        format!("{bp}/{rp}")
    };

    let mut out = Vec::<u8>::new();
    out.extend_from_slice(
        format!("{} {} {}\r\n", req.method, forwarded_path, req.version).as_bytes(),
    );

    for line in original.split("\r\n").skip(1) {
        if line.is_empty() {
            continue;
        }
        let lower = line.to_ascii_lowercase();
        if lower.starts_with("host:") || lower.starts_with("connection:") {
            continue;
        }
        out.extend_from_slice(line.as_bytes());
        out.extend_from_slice(b"\r\n");
    }

    out.extend_from_slice(format!("Host: {}\r\n", upstream.host).as_bytes());
    out.extend_from_slice(b"Connection: close\r\n");
    out.extend_from_slice(b"\r\n");
    out.extend_from_slice(body);

    Ok(out)
}

/// Minimal response read: read until EOF (Connection: close).
fn read_all_response(stream: &mut TcpStream) -> Result<Vec<u8>> {
    let mut resp = Vec::<u8>::new();
    let mut tmp = [0u8; 8192];

    loop {
        let n = stream.read(&mut tmp).context("read upstream response")?;
        if n == 0 {
            break;
        }
        resp.extend_from_slice(&tmp[..n]);
        if resp.len() > MAX_RESP_BYTES {
            return Err(anyhow!("upstream response too large"));
        }
    }

    Ok(resp)
}

fn split_http_response(resp: &[u8]) -> Result<(Vec<u8>, Vec<u8>)> {
    let header_end = find_double_crlf(resp).ok_or_else(|| anyhow!("invalid upstream response"))?;
    let head = resp[..header_end].to_vec();
    let body = resp[header_end + 4..].to_vec();
    Ok((head, body))
}

fn parse_status_code_from_head(head: &[u8]) -> Result<u16> {
    let head_str = std::str::from_utf8(head).context("resp head not utf8")?;
    let status_line = head_str
        .split("\r\n")
        .next()
        .ok_or_else(|| anyhow!("missing status line"))?;
    let status = status_line
        .split_whitespace()
        .nth(1)
        .ok_or_else(|| anyhow!("missing status code"))?
        .parse::<u16>()
        .context("invalid status code")?;
    Ok(status)
}

fn build_response(
    status_line: &str,
    body: &[u8],
    workload: &str,
    content_type: Option<&str>,
    extra_headers: &[(&str, &str)],
) -> Vec<u8> {
    let mut out = Vec::<u8>::new();
    out.extend_from_slice(status_line.as_bytes());
    out.extend_from_slice(b"\r\n");

    if let Some(content_type) = content_type {
        out.extend_from_slice(format!("Content-Type: {content_type}\r\n").as_bytes());
    }

    out.extend_from_slice(format!("X-Gateway-Variant: {GATEWAY_VARIANT}\r\n").as_bytes());
    out.extend_from_slice(format!("X-Gateway-Workload: {workload}\r\n").as_bytes());

    for (name, value) in extra_headers {
        out.extend_from_slice(format!("{name}: {value}\r\n").as_bytes());
    }

    out.extend_from_slice(format!("Content-Length: {}\r\n", body.len()).as_bytes());
    out.extend_from_slice(b"Connection: close\r\n\r\n");
    out.extend_from_slice(body);
    out
}

fn rebuild_response_with_extra_headers(
    head: &[u8],
    body: &[u8],
    workload: &str,
    extra_headers: &[(&str, &str)],
) -> Result<Vec<u8>> {
    let head_str = std::str::from_utf8(head).context("resp head not utf8")?;

    let mut lines = head_str.split("\r\n");
    let status = lines.next().ok_or_else(|| anyhow!("missing status line"))?;

    let mut out = Vec::<u8>::new();
    out.extend_from_slice(status.as_bytes());
    out.extend_from_slice(b"\r\n");

    for line in lines {
        if line.is_empty() {
            continue;
        }
        let lower = line.to_ascii_lowercase();
        if lower.starts_with("content-length:")
            || lower.starts_with("connection:")
            || lower.starts_with("x-gateway-variant:")
            || lower.starts_with("x-gateway-workload:")
            || lower.starts_with("x-upstream-url:")
            || lower.starts_with("x-upstream-status:")
        {
            continue;
        }
        out.extend_from_slice(line.as_bytes());
        out.extend_from_slice(b"\r\n");
    }

    out.extend_from_slice(format!("X-Gateway-Variant: {GATEWAY_VARIANT}\r\n").as_bytes());
    out.extend_from_slice(format!("X-Gateway-Workload: {workload}\r\n").as_bytes());
    for (name, value) in extra_headers {
        out.extend_from_slice(format!("{name}: {value}\r\n").as_bytes());
    }
    out.extend_from_slice(format!("Content-Length: {}\r\n", body.len()).as_bytes());
    out.extend_from_slice(b"Connection: close\r\n\r\n");
    out.extend_from_slice(body);
    Ok(out)
}

fn wasm_transform(runtime: &str, module_path: &str, input: &[u8]) -> Result<Vec<u8>> {
    let mut cmd = match runtime {
        "wasmedge" => {
            let mut cmd = Command::new("wasmedge");
            cmd.arg(module_path);
            cmd
        }
        "wasmtime" => {
            let mut cmd = Command::new("wasmtime");
            cmd.arg("run").arg(module_path);
            cmd
        }
        _ => return Err(anyhow!("unsupported wasm runtime: {runtime}")),
    };

    let mut child = cmd
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .with_context(|| format!("failed to spawn {runtime} for module {module_path}"))?;

    {
        let stdin = child
            .stdin
            .as_mut()
            .ok_or_else(|| anyhow!("failed to open stdin for {runtime}"))?;
        stdin
            .write_all(input)
            .with_context(|| format!("failed writing input to {runtime}"))?;
    }

    let output = child
        .wait_with_output()
        .with_context(|| format!("failed waiting for {runtime} process"))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(anyhow!(
            "{runtime} exited with status {}: {}",
            output.status,
            stderr.trim()
        ));
    }

    Ok(output.stdout)
}

fn find_double_crlf(buf: &[u8]) -> Option<usize> {
    buf.windows(4).position(|w| w == b"\r\n\r\n")
}
