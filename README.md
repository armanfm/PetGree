# PetgreeChain

Identidade de saúde animal on-chain. Verificável, à prova de adulteração, e que não se perde quando o tutor muda, a clínica fecha ou a carteirinha some.

> Desafio ProofChain · Hackathon Web3 RESTIC 29

## O problema

O histórico de saúde de um animal hoje vive em uma carteirinha de papel ou em um sistema interno de clínica. Quando a carteirinha se perde, o animal precisa repetir vacinas e cumprir período de observação. Na adoção, sem o histórico, o protocolo é refazer do zero as vacinas obrigatórias, como a antirrábica e a V8 ou V10. Sobra gasto e estresse que poderiam ser evitados.

O dado existia. Ele só não estava em um lugar que sobrevivesse à troca de mãos.

## A solução

O PetgreeChain registra a identidade, as vacinas, os atendimentos e a memória de cada animal em blockchain. O histórico deixa de pertencer a uma clínica ou a um aplicativo e passa a pertencer ao próprio animal. É portátil entre tutores e clínicas, não pode ser adulterado depois de gravado e pode ser verificado por qualquer pessoa pelo endereço do contrato do pet.

O uso de blockchain se justifica por três razões. A portabilidade faz o histórico acompanhar o animal, e não quem o cadastrou. A imutabilidade impede que o registro seja alterado ou apagado. A verificação pública permite conferir as vacinas sem depender da palavra de uma única clínica.

## Arquitetura de dados

Nem todo dado vai para a blockchain. Cada tipo de informação tem uma exigência diferente de privacidade, permanência ou flexibilidade, e fica onde faz sentido.

| Camada | O que guarda | Por quê |
| --- | --- | --- |
| On-chain, imutável e público | Identidade do pet, vacinas, linhagem, registro de que a consulta ocorreu, memorial | Precisa durar e ser verificável por qualquer parte |
| Off-chain, privado, grava uma vez | Prontuário clínico, exames, laudos, diagnóstico | Dado sensível de saúde, que não pode ser público nem adulterado depois |
| Off-chain, editável | Preço de consulta e internação, contato, endereço da clínica | Informação comercial que muda e precisa ser corrigível |

A camada off-chain fica no Supabase. O desenho é conforme à LGPD e à GDPR por princípio: em uma blockchain pública não se apaga nem se corrige nada, então o dado sensível, por ética e por lei, fica fora dela.

## Contratos

O sistema tem três contratos em Solidity 0.8.20.

### PetFactory

Registra cada animal e implanta um `PetContract` próprio por pet. Valida a linhagem, ou seja, pai e mãe informados precisam ser contratos legítimos da própria fábrica, e injeta em cada novo pet as referências compartilhadas, o `VetNFT` e os feeds Chainlink. Mantém o índice global de pets e o mapeamento por dono.

Principais funções: `registerPet`, `getPetsByOwner`, `getAllPets`, `totalPets`, `isPetRegistered`. Evento: `PetRegistrado`.

### PetContract

O prontuário imutável de cada pet. Guarda consultas, vacinas, atestados e o memorial. Só o dono abre uma consulta, e só o veterinário responsável e ativo adiciona o registro público e finaliza. A vacinação é a única informação clínica pública. O memorial só pode ser aberto se houver ao menos uma vacinação registrada. Os feeds Chainlink ETH/USD e BRL/USD servem apenas para converter o preço em reais, já que o pagamento é presencial.

Tipos de atendimento: `CONSULTA`, `VACINACAO`, `INTERNACAO`, `CIRURGIA`, `OUTROS`. Modificadores de acesso: `apenasDono`, `apenasVetAtivo`, `petVivo`. Principais funções: `openConsultation`, `addRecord`, `finalizeConsultation`, `issueAtestado`, `markAsDeceased`, `converterParaReais`, além dos getters de consultas, atestados e memorial.

### VetNFT

Credencial soulbound, um ERC-721 intransferível, emitido ao veterinário após validação do CRMV e aprovação humana. O contrato bloqueia transferências sobrescrevendo a função interna de atualização do token. Cada aprovação ou suspensão fica rastreável on-chain pelo endereço de quem a executou, sem votação anônima.

Status da credencial: `INEXISTENTE`, `PENDENTE`, `ATIVA`, `SUSPENSA`. Principais funções: `registerVet`, `approveVet`, `registerVetByAdmin`, `suspendVet`, `reactivateVet`, `setPrices`, `isVetActive`, `getVetPrice`. Eventos com os campos `aprovadoPor` e `suspensoPor` para responsabilização individual.

## Contrato em testnet

> Preencher com os dados confirmados do deploy. Um endereço EVM não indica a rede, então confirme em qual rede o deploy foi feito e qual endereço é cada contrato. No explorador, a PetFactory é a que emite eventos `PetRegistrado` e responde a `getAllPets`.

- Rede: `[CONFIRMAR, provavelmente Ethereum Sepolia]`
- VetNFT: `[ENDEREÇO]`
- PetFactory: `[ENDEREÇO]`
- Explorador: `[LINK, ex.: https://sepolia.etherscan.io/address/...]`

## Stack

- Solidity 0.8.20
- OpenZeppelin (ERC-721, Ownable)
- Chainlink Price Feeds (ETH/USD e BRL/USD)
- Ethers.js 6.13.5, carregado por CDN (jsDelivr)
- MetaMask para assinatura
- Supabase para a camada off-chain
- Geoapify para a geocodificação do endereço da clínica

## Estrutura do repositório

```
/contracts   PetFactory.sol, PetContract.sol, VetNFT.sol
/frontend    index.html, aplicação estática que conecta via MetaMask
/scripts     scripts de apoio
/test        testes
/docs        documentação
```

## Como rodar

O projeto tem os contratos em Solidity e um frontend estático que usa Ethers.js por CDN e conecta pela MetaMask.

### 1. Implantar os contratos

Use o Remix ou o Hardhat na rede de teste escolhida. A ordem importa, porque a PetFactory depende do VetNFT.

1. Implante o `VetNFT` (sem parâmetros, quem implanta vira owner e admin).
2. Implante a `PetFactory` passando três endereços: o do `VetNFT`, o do feed Chainlink ETH/USD da rede e o do feed BRL/USD. Na Sepolia, onde não há feed BRL/USD, passe `address(0)` no terceiro parâmetro. Confirme o endereço do feed ETH/USD na documentação de price feeds da Chainlink.

### 2. Rodar o frontend

1. Abra `frontend/index.html` direto no navegador ou sirva a pasta com qualquer servidor estático.
2. Conecte a MetaMask na mesma rede de teste do deploy.
3. Informe na configuração do app os endereços do `PetFactory` e do `VetNFT`.

O frontend já traz a URL e a chave publishable do Supabase embutidas, então a camada off-chain funciona sem configuração extra. A busca de endereço da clínica usa a Geoapify, com a chave informada pelo próprio usuário no app, e é opcional.

## Testes e Segurança

[a preencher]

## Requisitos do ProofChain atendidos

- Registro on-chain: `PetFactory` e `PetContract` gravam identidade, vacinas e atendimentos.
- Consulta pública: qualquer pessoa lê o histórico pelo endereço do contrato do pet.
- Contrato em testnet: ver a seção acima.
- README funcional: este documento.
- Vídeo-pitch: `[LINK do YouTube, não listado]`

## Uso de inteligência artificial

Em conformidade com a política de uso de IA do Hackweb, declaramos as ferramentas utilizadas como apoio ao desenvolvimento:

- Claude (Anthropic): auxílio no desenvolvimento e na geração da documentação NatSpec dos contratos, revisada pela equipe.
- ChatGPT (OpenAI): auxílio durante o desenvolvimento.

A autoria intelectual, as decisões de arquitetura e a implementação da solução são da equipe. Nenhuma API ou dataset de IA foi integrado ao produto final.

## Equipe

- Armando José Freire de Melo, analista de sistemas e arquiteto blockchain.
- Izabela Fernandes Santos, advogada de direito internacional e web3.

## Licença

MIT. Ver o arquivo `LICENSE`.
