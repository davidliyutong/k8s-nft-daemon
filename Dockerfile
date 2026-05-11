FROM alpine:3.21

# Install nftables — provides the nft(8) CLI used by entrypoint.sh.
# iptables-legacy is included so the image works on nodes that still
# use the xtables back-end alongside nf_tables.
RUN apk add --no-cache nftables

COPY base/entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
