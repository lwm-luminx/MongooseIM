# Patches

One patch per proposed MongooseIM change, made with `git format-patch` against upstream `master`
(two are stacked, noted below). Each has an issue and a pull request in this fork.

Apply one with:

    git am patches/NN-name.patch

| Patch | Applies on |
|---|---|
| 01-mam-admin-delete | master |
| 02-mam-muc-remove-user | master + 01 |
| 03-muc-moderated-retraction | master |
| 04-mam-retract-v1 | master |
| 05-muc-occupant-id | master |
| 06-jwt-auth-keys-and-claims | master |
| 07-graphql-admin-jwt | master |
| 08-graphql-sse-session-resource | master |
| 09-graphql-sse-presences | master + 08 |
| 10-blocking-admin-api | master |
| 11-muc-hats | master |
