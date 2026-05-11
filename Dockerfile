FROM alpine:3.21

# Install nftables — provides the nft(8) CLI used by entrypoint.sh.
# Alpine supports all three target platforms natively:
#   linux/amd64  · linux/arm64  · linux/arm/v7
RUN apk add --no-cache nftables

COPY base/entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
