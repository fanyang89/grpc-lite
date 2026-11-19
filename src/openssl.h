#include <openssl/err.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>

#if !(OPENSSL_VERSION_MAJOR == 4 || (OPENSSL_VERSION_MAJOR == 3 && OPENSSL_VERSION_MINOR >= 5))
#error "grpc-lite requires OpenSSL 3.5+ (3.x) or 4.x development files"
#endif

enum { GRPC_SSL_NO_RENEGOTIATION = SSL_OP_NO_RENEGOTIATION };
