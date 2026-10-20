//! RFC 9180 vector distributed by rust-hpke (test-vectors-5f503c5.json, MIT/Apache-2.0).
use hpke::{
    Deserializable, Kem, OpModeR, aead::ChaCha20Poly1305, kdf::HkdfSha256, kem::X25519HkdfSha256,
};
#[test]
fn rfc9180_authenticated_x25519_chacha20_known_answer() {
    type K = X25519HkdfSha256;
    let v: serde_json::Value =
        serde_json::from_str(include_str!("fixtures/hpke-auth-x25519.json")).unwrap();
    let bytes = |key: &str| hex::decode(v[key].as_str().unwrap()).unwrap();
    let sk = <K as Kem>::PrivateKey::from_bytes(&bytes("skRm")).unwrap();
    let pk = <K as Kem>::PublicKey::from_bytes(&bytes("pkSm")).unwrap();
    let enc = <K as Kem>::EncappedKey::from_bytes(&bytes("enc")).unwrap();
    let mut receiver = hpke::setup_receiver::<ChaCha20Poly1305, HkdfSha256, K>(
        &OpModeR::Auth(pk),
        &sk,
        &enc,
        &bytes("info"),
    )
    .unwrap();
    let encryption = &v["encryptions"][0];
    let ciphertext = hex::decode(encryption["ct"].as_str().unwrap()).unwrap();
    let aad = hex::decode(encryption["aad"].as_str().unwrap()).unwrap();
    let plaintext = receiver.open(&ciphertext, &aad).unwrap();
    assert_eq!(hex::encode(plaintext), encryption["pt"].as_str().unwrap());
}
