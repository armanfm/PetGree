-include .env

build:
	forge build

test:
	forge test

deploy:
	forge script src/DeploySeuToken.s.sol --rpc-url $(RPC_URL) --private-key $(PRIVATE_KEY) --broadcast

deploy-local:
	forge script src/DeploySeuToken.s.sol --rpc-url http://localhost:8545 --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 --broadcast
