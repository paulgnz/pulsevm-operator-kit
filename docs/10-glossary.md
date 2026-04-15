# 10 — Glossary

Quick-reference for terms that appear throughout this wiki.

| Term | Meaning |
|---|---|
| **ABI** | Application Binary Interface — JSON schema describing a contract's actions and tables, used by clients to encode/decode action data. |
| **A-Chain** | XPR Network's name for its upcoming Metal Superstack integration. Strongly inferred to be implemented by PulseVM. |
| **Antelope** | Post-EOSIO rebrand of the protocol maintained by the EOS Network Foundation. Umbrella over Leap / Spring. |
| **AvalancheGo** | The Go reference node for Avalanche. MetalGo is a fork. |
| **Chainbase** | C++ `boost::multi_index_container`-based transactional database; Antelope's state store. PulseVM links it in via FFI. |
| **Deferred transaction** | Antelope feature allowing on-chain scheduling of a tx for a later block. **Not supported in PulseVM.** |
| **DPoS** | Delegated Proof of Stake; Antelope's traditional consensus. PulseVM replaces it with Snowman. |
| **FFI** | Foreign Function Interface. PulseVM uses Rust's `cxx` crate to call C++ Chainbase. |
| **Hyperion** | EOS Rio's history/indexer API for Antelope chains. `pulsevm-hyperion` is a fork. |
| **Intrinsic** | Host function importable from a WASM contract (e.g. `require_auth`, `db_store_i64`). |
| **K1 / R1 / WA** | Signature types: K1 = secp256k1, R1 = P-256, WA = WebAuthn. All supported. |
| **Leap** | EOS Network Foundation's Antelope node implementation (C++). |
| **LIB** | Last Irreversible Block. Under Snowman it's much closer to the head than under DPoS. |
| **Metal Blockchain** | Metallicus's L0 infra; AvalancheGo fork with P, X, C, A chains + subnets. |
| **MetalGo** | The node binary for Metal Blockchain (fork of AvalancheGo). Loads PulseVM as a plugin. |
| **Metallicus** | US fintech behind Metal Pay, Metal X, Metal Blockchain, XPR Network. |
| **Multi-index** | Antelope's primary+secondary-indexed table API. PulseVM today supports primary only. |
| **Name** | 13-char-max (12 usable) base32-encoded 64-bit identifier for accounts/actions/tables/permissions. |
| **nodeos** | Old name for the Antelope C++ daemon (now `leap-node`). |
| **Pulse / `pulse` account** | Reserved system account on PulseVM (like `eosio` on Antelope). |
| **PulseVM** | Glenn Marien's Rust Antelope-compatible VM running as a Metal Blockchain subnet. |
| **SHiP** | State History Plugin — nodeos's WebSocket stream of blocks and deltas. PulseVM exposes a compatible stream. |
| **Snowman** | Avalanche's linear-chain consensus protocol. Delivers finality in ~200 ms. |
| **Spring** | Another Antelope node implementation (by ENF). |
| **Subnet** | An Avalanche construct: a set of validators running one or more blockchains with their own VMs. |
| **Superstack** | Metal Blockchain's multi-chain / multi-subnet product narrative. |
| **SYS** | PulseVM's default resource token symbol. |
| **Wasmer** | WebAssembly runtime used by PulseVM (LLVM backend, with instruction-metering middleware). |
| **wasm32-unknown-unknown** | Rust's standard WASM target; what `pulse-cdt-rust` compiles to. |
| **XPR / XPR Network** | Formerly Proton. Antelope chain stewarded by Metallicus. |
