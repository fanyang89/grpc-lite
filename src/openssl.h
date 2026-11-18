#include <openssl/err.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>

#if OPENSSL_VERSION_MAJOR != 4
#error "grpc-lite native TLS requires OpenSSL 4.x development files"
#endif

enum { GRPC_SSL_NO_RENEGOTIATION = SSL_OP_NO_RENEGOTIATION };
