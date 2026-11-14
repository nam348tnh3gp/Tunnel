class ArgInfo {
  const ArgInfo(this.flag, this.desc);
  final String flag;
  final String desc;
}

const List<ArgInfo> kCloudflaredArguments = [
  ArgInfo('--output', 'Output format for logs (default, json)'),
  ArgInfo('--loglevel', 'Application log level (debug, info, warn, error, fatal)'),
  ArgInfo('--transport-loglevel', 'Transport log level'),
  ArgInfo('--retries', 'Max connection retries (default 5)'),
  ArgInfo('--grace-period', 'Time to wait for in-flight requests on shutdown'),
  ArgInfo('--no-autoupdate', 'Disable automatic updates'),
  ArgInfo('--proxy-dns', 'Enable DNS proxy'),
  ArgInfo('--proxy-dns-port', 'DNS proxy port'),
  ArgInfo('--proxy-dns-address', 'DNS proxy address'),
  ArgInfo('--proxy-dns-upstream', 'DNS upstream (multiple allowed)'),
  ArgInfo('--proxy-dns-max-upstream-conns', 'Max upstream connections'),
  ArgInfo('--proxy-dns-bootstrap', 'DNS bootstrap (multiple allowed)'),
  ArgInfo('--credentials-file', 'Path to tunnel credentials file'),
  ArgInfo('--region', 'Cloudflare edge region'),
  ArgInfo('--edge-ip-version', 'Edge IP version {4, 6, auto}'),
  ArgInfo('--edge-bind-address', 'Bind to IP for outgoing connections'),
  ArgInfo('--label', 'Custom label for connector'),
  ArgInfo('--post-quantum', 'Enable post-quantum secure tunnel'),
  ArgInfo('--management-diagnostics', 'Enable diagnostic routes'),
  ArgInfo('--overwrite-dns', 'Overwrite existing DNS records'),
  ArgInfo('--protocol', 'Protocol {auto, quic, http2}'),
  ArgInfo('--no-tls-verify', 'Disable TLS verification (insecure)'),
];
