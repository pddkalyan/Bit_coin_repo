# Mainnet-fork validation — unmodified Solidity from original file

- Master file checksum: `b26db4d71abbb883ffce1be182750f377df49c5eb35dd062ff042a5d526f114d`.
- Solidity and seven embedded Foundry tests extracted from that file without changing executable Solidity.
- Real historical Ethereum mainnet state fork pinned at block `25733035`; public archival RPC is required.
- Added five independent access/rollback checks in separate test file.
- **NO funded wallet, mainnet transaction, signing key or gas expenditure.**
- The positive original proofs artificially push prices with a simulated whale, so their success can only show execution mechanics.
- Keeper, Flashbots bundle submission, net native-gas performance, audited custody and production profitability remain out of scope.
