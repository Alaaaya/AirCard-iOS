#!/bin/sh
set -eu
cd "$(dirname "$0")"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=Mirsa-Test-CA -keyout "$tmp/ca.key" -out "$tmp/ca.pem" -days 3650 2>/dev/null
openssl req -newkey rsa:2048 -nodes -subj /CN=Mirsa-Test-Leaf -keyout "$tmp/leaf.key" -out "$tmp/leaf.csr" 2>/dev/null
openssl x509 -req -in "$tmp/leaf.csr" -CA "$tmp/ca.pem" -CAkey "$tmp/ca.key" -CAcreateserial -out "$tmp/leaf.pem" -days 3650 2>/dev/null
openssl x509 -req -in "$tmp/leaf.csr" -CA "$tmp/ca.pem" -CAkey "$tmp/ca.key" -set_serial 999 -out "$tmp/alternate.pem" -days 3650 2>/dev/null
openssl x509 -in "$tmp/alternate.pem" -outform DER -out alternate.der
openssl x509 -in "$tmp/leaf.pem" -outform DER -out leaf.der
openssl pkcs12 -export -inkey "$tmp/leaf.key" -in "$tmp/leaf.pem" -out legacy.p12 -legacy -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-RC2-40 -passout pass:mirsa-test
openssl pkcs12 -export -inkey "$tmp/leaf.key" -in "$tmp/leaf.pem" -out modern.p12 -keypbe AES-256-CBC -certpbe AES-256-CBC -passout pass:mirsa-test
openssl pkcs12 -export -inkey "$tmp/leaf.key" -in "$tmp/leaf.pem" -certfile "$tmp/ca.pem" -out chain.p12 -passout pass:mirsa-test
openssl pkcs12 -export -nokeys -in "$tmp/leaf.pem" -out cert-only.p12 -passout pass:mirsa-test
