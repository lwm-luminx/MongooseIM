# JWT

## Overview

This authentication method can verify [JSON Web Tokens](https://jwt.io) provided by the clients.
A wide range of signature algorithms is supported, including those using public key cryptography.

The module checks the signature and validity of the following parameters:

* `exp` - an expired token is rejected,
* `iat` - a token must be issued in the past,
* `nbf` - a token might not be valid *yet*.

These claims are checked only when they are present in the token.
A token without `exp` never expires, so make sure that your token issuer always sets it.

Optionally, the module can also check the issuer (`iss`), the audience (`aud`) and the domain of the user.
Several keys can be configured at the same time, which makes it possible to rotate the signing keys without downtime.

It requires the `SASL PLAIN` mechanism listed in `sasl_mechanisms`.

## Configuration options

### `auth.jwt.secret`
* **Syntax:** TOML table with exactly one of the possible items listed below:
    * `file` - string, path to the file with the JWT secret,
    * `env`- string, environment variable name with the JWT secret,
    * `value` - string, the JWT secret value.
* **Default:** no default, this option is mandatory unless `keys` are specified
* **Example:** `secret.env = "JWT_SECRET"`

This is the JWT secret used for the authentication. You can store it in a file, as an environment variable or specify it directly.
For public key algorithms, it is the public key in the PEM format.
A file is read when the module starts, while an environment variable is read for each authentication attempt.

### `auth.jwt.algorithm`
* **Syntax:** string, one of: `"HS256"`, `"RS256"`, `"ES256"`, `"HS384"`, `"RS384"`, `"ES384"`, `"HS512"`, `"RS512"`, `"ES512"`
* **Default:** no default, this option is mandatory when `secret` is specified
* **Example:** `algorithm = "HS512"`

Name of the algorithm used to sign the JWT.

### `auth.jwt.keys`
* **Syntax:** array of TOML tables with the following items:
    * `secret` - mandatory, the same as `auth.jwt.secret`,
    * `algorithm` - mandatory, the same as `auth.jwt.algorithm`,
    * `kid` - optional string, the key ID.
* **Default:** `[]`
* **Example:** `keys = [{kid = "2024-01", secret.env = "JWT_KEY_1", algorithm = "HS256"}]`

Additional keys used to verify the tokens. They are tried in order, after the key specified with `secret` and `algorithm` (if any).
When the token header contains a `kid`, only the keys with the same `kid` and the keys without a `kid` are tried.
At least one key needs to be configured, either with `secret` or with `keys`.

### `auth.jwt.username_key`
* **Syntax:** string
* **Default:** no default, this option is mandatory
* **Example:** `username_key = "user_name"`

Name of the JWT key that contains the user name to verify.

### `auth.jwt.domain_key`
* **Syntax:** string
* **Default:** not set
* **Example:** `domain_key = "domain"`

Name of the JWT key that contains the domain of the user. When set, the token is accepted only if this claim is equal to the domain the user is authenticating for.
This prevents a token issued for a user in one domain from being used in another domain served by the same host type.

### `auth.jwt.issuer`
* **Syntax:** string
* **Default:** not set
* **Example:** `issuer = "https://auth.example.com"`

When set, the token is accepted only if its `iss` claim is equal to this value.

### `auth.jwt.audience`
* **Syntax:** string
* **Default:** not set
* **Example:** `audience = "xmpp.example.com"`

When set, the token is accepted only if its `aud` claim is equal to this value, or is a list containing it.

### Example

```toml
[auth.jwt]
  secret.value = "top-secret123"
  algorithm = "HS256"
  username_key = "user"
```

Example with two keys, used to rotate the signing key, and additional claim checks:

```toml
[auth.jwt]
  username_key = "sub"
  domain_key = "domain"
  issuer = "https://auth.example.com"
  audience = "xmpp.example.com"

  [[auth.jwt.keys]]
    kid = "2025-02"
    secret.env = "JWT_KEY_NEW"
    algorithm = "HS256"

  [[auth.jwt.keys]]
    kid = "2025-01"
    secret.file = "/etc/mongooseim/jwt_old.key"
    algorithm = "HS256"
```

The claims of the token are not logged, because they might contain personal data.
