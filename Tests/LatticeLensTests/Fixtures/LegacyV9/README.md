# 1.0.11 V9 schema fixture

`LatticeLens-v8.store` is a fresh, project-local store initialized by the preserved
LatticeLens 1.0.11 app bundle. Its Core Data version identifier is `9.0.0`, and its
`Z_METADATA` contains 50 model version hashes. The only non-empty entity tables are
the app bootstrap `StoredV8StoreMarker` and `StoredV8SearchIndexState`; it contains
no paper, author, document, or user-library records.

Fixture SHA-256: `adebcf319ac76951cc1e9e6a514a7376b1e53b19bc5f3c2ed8b7099b4858b2c6`.
The `StoredV8FullTextDocument` entity version hash is
`3274a16d14e9093b44cb490e237fc8e12f7a0f0ac8ffbf7e3831d937019f8cfc`.

The V9 compatibility and G02 rollback tests copy this file into a fresh
project-local test root before opening it. They must never modify this fixture in
place. The 1.0.11 model already persists the index version, count, completeness,
and failure summary columns. Only the subsequently added inventory-hash property
is transient in the V9 entity; durable source-bound formula state is stored in
the typed V10 inventory rows.
