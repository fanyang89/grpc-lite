# TLS Test Credentials

`localhost-cert.pem` and `localhost-key.pem` are public test-only credentials. Never use
them outside this repository's automated tests. The self-signed certificate covers
`localhost` and `127.0.0.1` and expires on 2036-07-23.

They were generated with:

```bash
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -subj '/CN=localhost' \
  -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' \
  -addext 'basicConstraints=critical,CA:TRUE' \
  -addext 'keyUsage=critical,keyCertSign,digitalSignature,keyEncipherment' \
  -keyout localhost-key.pem -out localhost-cert.pem
```

`ipv6-cert.pem` reuses the same test key and additionally covers the `::1` IP SAN.
It expires on 2036-10-27. Keep the original certificate for the negative IPv6 SAN
test: trusting its issuer must not authorize an IPv6 identity it does not contain.

```bash
openssl req -new -x509 -key localhost-key.pem -sha256 -days 3650 \
  -subj '/CN=localhost' \
  -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1' \
  -addext 'basicConstraints=critical,CA:TRUE' -out ipv6-cert.pem
```
