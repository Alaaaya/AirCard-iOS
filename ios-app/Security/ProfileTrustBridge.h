#ifndef MIRSA_PROFILE_TRUST_BRIDGE_H
#define MIRSA_PROFILE_TRUST_BRIDGE_H
#include <stddef.h>
#include <stdint.h>
// signer_der is the CMS signature-verified SID-selected signer, not an arbitrary embedded cert.
// Packet consists of at most 16 u32-BE length + DER pairs, <=64KiB each, <=256KiB total.
int32_t mirsa_verify_profile_signer_chain(const uint8_t *signer_der, size_t signer_len,
                                        const uint8_t *chain_packet, size_t packet_len);
#endif
