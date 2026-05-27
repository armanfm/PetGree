// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title VetNFT - Credencial NFT Soulbound para veterinarios
/// @notice Emite uma credencial NFT intransferivel (soulbound) que comprova que um
///         endereco e um veterinario aprovado na plataforma. A aprovacao e manual,
///         feita pelo owner ou por um endereco de governanca autorizado.
/// @dev Herda de ERC721 (token) e Ownable (controle de acesso do owner).
///      O NFT e soulbound: uma vez mintado, fica permanentemente vinculado ao
///      endereco que o recebeu (ver override de _update).
contract VetNFT is ERC721, Ownable {

    // STRUCTS

    /// @notice Dados completos de um veterinario cadastrado
    /// @dev `ativo` e `tokenId` so sao preenchidos no momento do mint (_mintVet)
    struct Vet {
        string nome;                    // nome do veterinario
        string crmv;                    // registro profissional (CRMV)
        string cidade;                  // cidade de atuacao
        string bairro;                  // bairro de atuacao
        string telefone;                // telefone de contato
        uint256 consultaPrice;          // preco base de consulta (em wei)
        uint256 diariaInternacaoPrice;  // preco da diaria de internacao (em wei)
        bool ativo;                     // true se o vet esta ativo e pode operar
        uint256 tokenId;                // id do NFT soulbound deste vet
    }

    // STATE

    uint256 private _tokenIdCounter;        // contador incremental para gerar ids unicos dos NFTs
    address public governance;              // endereco da governanca/admin autorizado alem do owner

    mapping(address => Vet) public vets;    // busca rapida dos dados do vet pelo endereco
    mapping(address => bool) public hasNFT; // verifica rapidamente se o endereco ja possui NFT
    address[] private _vetList;             // lista iteravel usada para listagem e contagem dos vets

    // EVENTS

    /// @notice Emitido quando um vet solicita cadastro (ainda sem aprovacao)
    event VetSolicitado(address indexed vet, string crmv, string cidade, string bairro, string telefone);
    /// @notice Emitido quando um vet e efetivamente aprovado e recebe o NFT
    event VetRegistrado(address indexed vet, string crmv, string cidade, string bairro, string telefone, uint256 tokenId);
    /// @notice Emitido quando um vet e desativado pelo owner
    event VetInativado(address indexed vet);
    /// @notice Emitido quando um vet atualiza seu preco de consulta
    event PrecoAtualizado(address indexed vet, uint256 novoPreco);
    /// @notice Emitido quando um vet atualiza seu telefone (ou localidade)
    event TelefoneAtualizado(address indexed vet, string novoTelefone);
    /// @notice Emitido quando o endereco de governanca e alterado
    event GovernanceAtualizada(address indexed governance);

    // CONSTRUCTOR

    /// @notice Inicializa o NFT com nome/simbolo e define o deployer como owner
    /// @dev ERC721("PetgreeChain Vet", "PGVET") define os metadados da colecao;
    ///      Ownable(msg.sender) define quem fez o deploy como owner inicial.
    constructor()
        ERC721("PetgreeChain Vet", "PGVET")
        Ownable(msg.sender)
    {}

    /// @notice Restringe a chamada ao owner do contrato ou ao endereco de governanca
    modifier onlyOwnerOrGovernance() {
        require(
            msg.sender == owner() || msg.sender == governance,
            "Apenas owner ou governanca"
        );
        _;
    }

    // SOULBOUND

    /// @notice Hook interno do ERC721 chamado em todo mint, transferencia e burn
    /// @dev Torna o token soulbound: so permite a operacao quando `from == address(0)`,
    ///      ou seja, apenas no mint. Qualquer transferencia posterior (from != 0) reverte,
    ///      mantendo o tokenId permanentemente vinculado ao endereco que o recebeu.
    /// @param to      endereco de destino
    /// @param tokenId id do token sendo movimentado
    /// @param auth    endereco autorizado a operar (controle interno do OZ)
    /// @return endereco anterior dono do token (padrao do OZ v5)
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override returns (address) {
        address from = _ownerOf(tokenId);

        require(
            from == address(0),
            "VetNFT: soulbound, nao transferivel"
        );

        return super._update(to, tokenId, auth);
    }

    // REGISTRO

    /// @notice Permite que um veterinario solicite cadastro na plataforma
    /// @dev NAO minta o NFT: apenas armazena os dados com ativo=false. A aprovacao
    ///      ocorre depois via approveVet (owner) ou pela governanca. Reverte se o
    ///      endereco ja possui NFT.
    /// @param nome     nome do veterinario
    /// @param crmv     registro profissional (CRMV)
    /// @param cidade   cidade de atuacao
    /// @param bairro   bairro de atuacao
    /// @param telefone telefone de contato
    function registerVet(
        string calldata nome,
        string calldata crmv,
        string calldata cidade,
        string calldata bairro,
        string calldata telefone
    ) external {
        require(!hasNFT[msg.sender], "Vet ja registrado");
        require(bytes(nome).length > 0, "Nome invalido");
        require(bytes(crmv).length > 0, "CRMV invalido");
        require(bytes(cidade).length > 0, "Cidade invalida");
        require(bytes(bairro).length > 0, "Bairro invalido");
        require(bytes(telefone).length > 0, "Telefone invalido");

        // Armazena os dados como solicitacao pendente (ativo=false, tokenId=0)
        vets[msg.sender] = Vet({
            nome: nome,
            crmv: crmv,
            cidade: cidade,
            bairro: bairro,
            telefone: telefone,
            consultaPrice: 0,
            diariaInternacaoPrice: 0,
            ativo: false,
            tokenId: 0
        });

        emit VetSolicitado(msg.sender, crmv, cidade, bairro, telefone);
    }

    // GOVERNANCA / ADMIN

    /// @notice Aprova um vet que ja solicitou cadastro via registerVet, mintando o NFT
    /// @dev Impede que um endereco ja aprovado receba um segundo NFT (double-mint).
    ///      Vets nao aprovados podem ser aprovados a qualquer momento pelo owner.
    ///      Nota: o sistema nao impede que o mesmo profissional use outro endereco.
    /// @param vetAddress endereco do vet a ser aprovado (precisa ter chamado registerVet antes)
    function approveVet(address vetAddress) external onlyOwner {
        require(!hasNFT[vetAddress], "Ja aprovado");
        require(bytes(vets[vetAddress].nome).length > 0, "Vet inexistente");

        _mintVet(vetAddress);
    }

    /// @notice Cadastra E aprova um vet em uma unica transacao (owner ou governanca)
    /// @dev Diferente do fluxo de dois passos (registerVet -> approveVet), aqui o
    ///      owner/governanca preenche os dados e minta o NFT direto. Util para
    ///      cadastros manuais ou aprovacao via votacao da governanca.
    ///      Aviso: se o vet ja havia chamado registerVet(), os dados anteriores
    ///      sao sobrescritos pelos dados passados aqui.
    /// @param vetAddress endereco do vet a registrar
    /// @param nome       nome do veterinario
    /// @param crmv       registro profissional (CRMV)
    /// @param cidade     cidade de atuacao
    /// @param bairro     bairro de atuacao
    /// @param telefone   telefone de contato
    function registerVetByGovernance(
        address vetAddress,
        string calldata nome,
        string calldata crmv,
        string calldata cidade,
        string calldata bairro,
        string calldata telefone
    ) external onlyOwnerOrGovernance {
        require(vetAddress != address(0), "Endereco invalido");
        require(!hasNFT[vetAddress], "Ja aprovado");
        require(bytes(nome).length > 0, "Nome invalido");
        require(bytes(crmv).length > 0, "CRMV invalido");
        require(bytes(cidade).length > 0, "Cidade invalida");
        require(bytes(bairro).length > 0, "Bairro invalido");
        require(bytes(telefone).length > 0, "Telefone invalido");

        // Preenche/sobrescreve os dados do vet antes de mintar
        vets[vetAddress].nome = nome;
        vets[vetAddress].crmv = crmv;
        vets[vetAddress].cidade = cidade;
        vets[vetAddress].bairro = bairro;
        vets[vetAddress].telefone = telefone;

        _mintVet(vetAddress);
    }

    /// @notice Permite que o proprio vet atualize cidade, bairro e telefone
    /// @dev So pode ser chamada por um vet que ja possui NFT.
    /// @param cidade   nova cidade
    /// @param bairro   novo bairro
    /// @param telefone novo telefone
    function updateLocalidade(
        string calldata cidade,
        string calldata bairro,
        string calldata telefone
    ) external {
        require(hasNFT[msg.sender], "Vet inexistente");
        require(bytes(cidade).length > 0, "Cidade invalida");
        require(bytes(bairro).length > 0, "Bairro invalido");
        require(bytes(telefone).length > 0, "Telefone invalido");

        vets[msg.sender].cidade = cidade;
        vets[msg.sender].bairro = bairro;
        vets[msg.sender].telefone = telefone;

        emit TelefoneAtualizado(msg.sender, telefone);
    }

    /// @notice Permite que o proprio vet atualize apenas o telefone
    /// @param novoTelefone novo telefone de contato
    function atualizarTelefone(string calldata novoTelefone) external {
        require(hasNFT[msg.sender], "Vet inexistente");
        require(bytes(novoTelefone).length > 0, "Telefone invalido");

        vets[msg.sender].telefone = novoTelefone;

        emit TelefoneAtualizado(msg.sender, novoTelefone);
    }

    /// @notice Define o endereco de governanca autorizado (alem do owner)
    /// @dev Tipicamente sera o endereco do contrato VetGovernance.
    /// @param governanceAddress endereco a ser autorizado como governanca
    function setGovernance(address governanceAddress) external onlyOwner {
        require(governanceAddress != address(0), "Endereco invalido");
        governance = governanceAddress;

        emit GovernanceAtualizada(governanceAddress);
    }

    /// @notice Desativa um vet (ele perde o status ativo, mas mantem o NFT)
    /// @dev Apenas marca ativo=false; nao queima o NFT (soulbound nao permite burn aqui).
    ///      Nao existe funcao de reativacao no contrato atual.
    /// @param vetAddress endereco do vet a desativar
    function deactivateVet(address vetAddress)
        external
        onlyOwner
    {
        require(hasNFT[vetAddress], "Vet inexistente");

        vets[vetAddress].ativo = false;

        emit VetInativado(vetAddress);
    }

    // PRECO

    /// @notice Permite que um vet ativo defina seus precos de consulta e internacao
    /// @dev Valores em wei. So pode ser chamada por vet que possui NFT e esta ativo.
    /// @param consultaPrice          preco base da consulta (wei)
    /// @param diariaInternacaoPrice  preco da diaria de internacao (wei)
    function setPrices(
        uint256 consultaPrice,
        uint256 diariaInternacaoPrice
    ) external {
        require(
            hasNFT[msg.sender] &&
            vets[msg.sender].ativo,
            "Apenas vets ativos"
        );

        vets[msg.sender].consultaPrice = consultaPrice;
        vets[msg.sender].diariaInternacaoPrice = diariaInternacaoPrice;

        emit PrecoAtualizado(msg.sender, consultaPrice);
    }

    // VIEWS

    /// @notice Verifica se um endereco e um vet ativo (possui NFT e esta ativo)
    /// @param vetAddress endereco a verificar
    /// @return true se o vet possui NFT e esta ativo
    function isVetActive(address vetAddress)
        external
        view
        returns (bool)
    {
        return hasNFT[vetAddress] &&
               vets[vetAddress].ativo;
    }

    /// @notice Retorna o preco a ser cobrado conforme o tipo de atendimento
    /// @dev Os tipos seguem o enum TipoConsulta do PetContract:
    ///      0=CONSULTA, 1=VACINACAO, 3=CIRURGIA, 4=OUTROS -> usam consultaPrice;
    ///      2=INTERNACAO -> diariaInternacaoPrice * diasInternacao.
    ///      Reverte se o tipo for invalido.
    /// @param vetAddress     endereco do vet
    /// @param tipo           codigo do tipo de atendimento (ver enum acima)
    /// @param diasInternacao numero de diarias (usado apenas para internacao)
    /// @return preco total calculado em wei
    function getVetPrice(
        address vetAddress,
        uint8 tipo,
        uint256 diasInternacao
    )
        external
        view
        returns (uint256)
    {
        Vet memory vet = vets[vetAddress];

        if (tipo == 0 || tipo == 1 || tipo == 3 || tipo == 4) {
            return vet.consultaPrice;
        }
        if (tipo == 2) return vet.diariaInternacaoPrice * diasInternacao;

        revert("Tipo invalido");
    }

    /// @notice Retorna todos os dados de um vet
    /// @param vetAddress endereco do vet
    /// @return struct Vet completa
    function getVet(address vetAddress)
        external
        view
        returns (Vet memory)
    {
        return vets[vetAddress];
    }

    /// @notice Retorna a lista de todos os enderecos de vets que receberam NFT
    /// @dev A lista cresce indefinidamente; pode ficar cara com muitos vets.
    /// @return array com todos os enderecos de vets registrados
    function getAllVets() external view returns (address[] memory) {
        return _vetList;
    }

    /// @notice Logica interna de mint compartilhada por approveVet e registerVetByGovernance
    /// @dev Incrementa o contador, minta o NFT soulbound, marca o vet como ativo,
    ///      registra no mapping e na lista iteravel, e emite VetRegistrado.
    /// @param vetAddress endereco que recebera o NFT
    function _mintVet(address vetAddress) internal {
        _tokenIdCounter++;

        uint256 tokenId = _tokenIdCounter;

        _safeMint(vetAddress, tokenId);

        vets[vetAddress].ativo = true;
        vets[vetAddress].tokenId = tokenId;

        hasNFT[vetAddress] = true;
        _vetList.push(vetAddress);

        emit VetRegistrado(
            vetAddress,
            vets[vetAddress].crmv,
            vets[vetAddress].cidade,
            vets[vetAddress].bairro,
            vets[vetAddress].telefone,
            tokenId
        );
    }
}
