# grpc-lite

A lightweight gRPC core runtime for Zig. The runtime uses upstream `nghttp2` and
`libuv`, while keeping protobuf encoding separate from transport.

## Status

The Zig rewrite currently targets unary RPC over cleartext HTTP/2. Streaming, TLS,
compression, generated protobuf code, retries, and service discovery are outside the
first phase.

## Development

```bash
mise install
mise run bootstrap
mise run check
```

The repository pins Zig and build tools in `mise.toml`. Native dependencies are pinned
as Git submodules and built from source.

## License

MIT
