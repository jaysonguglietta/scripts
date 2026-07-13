# Security

## OMDb Credentials

`convert.sh` does not contain a default OMDb API key. Configure `OMDB_API_KEY` at runtime from a protected environment file and never commit that file.

An OMDb key was embedded in older revisions of this public repository. Removing it from the current source does not remove it from Git history, forks, caches, or existing clones. The exposed key must be revoked or rotated through the OMDb account that issued it.

After rotation:

- Store the replacement key outside Git with permissions limited to the service account.
- Avoid placing the key directly in shell history, service unit text, logs, or issue reports.
- Keep `OMDB_URL` on HTTPS.
- Do not share verbose traces until they have been reviewed for unrelated sensitive paths or environment data.

The current API request implementation reads the key into `curl` through standard input rather than including it in the process argument list.

## History Rewriting

Purging the old key from Git history is separate from rotating it. A history rewrite requires a force-push, changes commit IDs, disrupts existing clones and open work, and cannot remove copies already fetched by others. Coordinate it explicitly with every repository user before using a tool such as `git filter-repo`.

Credential rotation is still required even if history is rewritten.

## File Safety

The converter reserves output names, writes each conversion in an adjacent hidden worker directory, validates it, and atomically moves it to the final path. Existing MP4 files are not overwritten. Source MKV files are not changed or deleted.

The normal interrupt handler terminates tracked worker process trees and cleans worker directories and reservations. `SIGKILL`, power loss, or a system crash cannot run cleanup; inspect ownership before manually removing a stale `.convert.lock` directory.

## Reporting

Do not open a public issue containing credentials, private media names, complete logs with sensitive paths, or exploit details. Contact the repository owner privately or use GitHub private vulnerability reporting if it is enabled for the repository.
