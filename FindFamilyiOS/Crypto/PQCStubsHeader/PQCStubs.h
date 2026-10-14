// PQCStubs.h — public header for the PQCStubs C target.
//
// The Rust PQC symbols are declared `@_silgen_name` in PQCCrypto.swift; this header
// gives the same symbols a proper C declaration for the SwiftPM C target so the
// symbols exist (weakly) at link time even without the real `libe2ee_pqc.a`.
// See PQCStubs.c for the fallback semantics.

#ifndef PQC_STUBS_H
#define PQC_STUBS_H

#include <stddef.h>
#include <stdint.h>

void pqc_free(uint8_t *ptr, size_t len);
void pqc_secure_zero(uint8_t *ptr, size_t len);
int32_t pqc_kem_keygen(
    uint8_t **pub_out, size_t *pub_len_out,
    uint8_t **priv_out, size_t *priv_len_out);
int32_t pqc_dsa_keygen(
    uint8_t **pub_out, size_t *pub_len_out,
    uint8_t **priv_out, size_t *priv_len_out);
int32_t pqc_identity_keygen(
    uint8_t **pub_bundle_out, size_t *pub_bundle_len_out,
    uint8_t **priv_bundle_out, size_t *priv_bundle_len_out);
int32_t pqc_link_keygen(
    uint8_t **seed_out, size_t *seed_len_out,
    uint8_t **pub_bundle_out, size_t *pub_bundle_len_out);
int32_t pqc_link_pub_from_seed(
    const uint8_t *seed, size_t seed_len,
    uint8_t **pub_bundle_out, size_t *pub_bundle_len_out);
int32_t pqc_kem_encaps(
    const uint8_t *kem_pub, size_t kem_pub_len,
    uint8_t **ct_out, size_t *ct_len_out,
    uint8_t **ss_out, size_t *ss_len_out);
int32_t pqc_kem_decaps(
    const uint8_t *kem_priv, size_t kem_priv_len,
    const uint8_t *ct, size_t ct_len,
    uint8_t **ss_out, size_t *ss_len_out);
int32_t pqc_dsa_sign(
    const uint8_t *dsa_priv, size_t dsa_priv_len,
    const uint8_t *msg, size_t msg_len,
    uint8_t **sig_out, size_t *sig_len_out);
int32_t pqc_dsa_verify(
    const uint8_t *dsa_pub, size_t dsa_pub_len,
    const uint8_t *msg, size_t msg_len,
    const uint8_t *sig, size_t sig_len);
int32_t pqc_security_code(
    const uint8_t *my_bundle, size_t my_bundle_len,
    const uint8_t *their_bundle, size_t their_bundle_len,
    uint8_t *out, size_t out_len);
int32_t pqc_bundle_is_valid(const uint8_t *bundle, size_t bundle_len);
int32_t pqc_bundle_inspect(
    const uint8_t *bundle, size_t bundle_len,
    size_t *kem_pub_len_out, size_t *dsa_pub_len_out);
int32_t pqc_bundle_build(
    const uint8_t *kem_pub, size_t kem_pub_len,
    const uint8_t *dsa_pub, size_t dsa_pub_len,
    uint8_t **out, size_t *out_len);
int32_t pqc_bundle_split(
    const uint8_t *bundle, size_t bundle_len,
    uint8_t **kem_pub_out, size_t *kem_pub_len_out,
    uint8_t **dsa_pub_out, size_t *dsa_pub_len_out);

#endif /* PQC_STUBS_H */
