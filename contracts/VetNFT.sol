// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title VetNFT - Credencial NFT Soulbound para veterinarios
/// @notice Emite credenciais NFT intransferiveis para veterinarios aprovados.
/// @dev Contato/localizacao ficam off-chain via API/Supabase.
///      Suporta multiplos admins: cada aprovacao fica rastreavel on-chain
///      pelo msg.sender, garantindo responsabilizacao individual.
///      Uma credencial pode ser suspensa e posteriormente reativada
///      (via reactivateVet) pelo owner ou admin, mantendo a mesma carteira e o mesmo NFT.
contract VetNFT is ERC721, Ownable {

    // ENUMS

    enum StatusCredencial {
        INEXISTENTE,  // nunca solicitou
        PENDENTE,     // solicitou, aguarda aprovacao
        ATIVA,        // aprovado, NFT mintado
        SUSPENSA      // credencial suspensa pelo owner/admin
    }

    // STRUCTS

    /// @notice Dados on-chain do veterinario (identidade + precos)
    /// @dev Contato e localizacao ficam no Supabase (tabela vet_locations)
    struct Vet {
        string nome;
        string crmv;
        uint256 consultaPrice;
        uint256 diariaInternacaoPrice;
        StatusCredencial status;
        uint256 tokenId;
    }

    // STATE

    uint256 private _tokenIdCounter;

    /// @notice Mapping de enderecos autorizados como administradores
    /// @dev Admins podem aprovar vets via registerVetByAdmin. Cada aprovacao
    ///      fica rastreavel na blockchain pelo msg.sender da transacao,
    ///      garantindo responsabilizacao individual (sem votacao anonima).
    mapping(address => bool) public admins;

    mapping(address => Vet) public vets;
    mapping(address => bool) public hasNFT;
    address[] private _vetList;

    // EVENTS

    event VetSolicitado(address indexed vet, string nome, string crmv);
    event VetRegistrado(address indexed vet, string nome, string crmv, uint256 tokenId, address indexed aprovadoPor);
    event VetSuspenso(address indexed vet, string crmv, uint256 tokenId, address indexed suspensoPor);
    event PrecosAtualizados(address indexed vet, uint256 consultaPrice, uint256 diariaInternacaoPrice);
    event AdminAdicionado(address indexed admin, address indexed adicionadoPor);
    event AdminRemovido(address indexed admin, address indexed removidoPor);

    // CONSTRUCTOR

    constructor()
        ERC721("PetgreeChain Vet", "PGVET")
        Ownable(msg.sender)
    {
        // O deployer ja e admin alem de owner
        admins[msg.sender] = true;
        emit AdminAdicionado(msg.sender, msg.sender);
    }

    // MODIFIERS

    /// @notice Restringe a chamada ao owner ou a qualquer admin autorizado
    modifier onlyOwnerOrAdmin() {
        require(
            msg.sender == owner() || admins[msg.sender],
            "Apenas owner ou admin"
        );
        _;
    }

    // SOULBOUND

    /// @notice Bloqueia transferencias: token permanece vinculado ao endereco que o recebeu
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

    // GESTAO DE ADMINS

    /// @notice Adiciona um novo administrador autorizado a aprovar/suspender vets
    /// @dev Apenas o owner pode adicionar admins. O evento registra quem adicionou.
    /// @param admin endereco a ser autorizado
    function addAdmin(address admin) external onlyOwner {
        require(admin != address(0), "Endereco invalido");
        require(!admins[admin], "Ja e admin");

        admins[admin] = true;

        emit AdminAdicionado(admin, msg.sender);
    }

    /// @notice Remove um administrador
    /// @dev O owner nao pode ser removido como admin por esta funcao.
    /// @param admin endereco a ser removido
    function removeAdmin(address admin) external onlyOwner {
        require(admin != owner(), "Owner nao pode ser removido");
        require(admins[admin], "Nao e admin");

        admins[admin] = false;

        emit AdminRemovido(admin, msg.sender);
    }

    /// @notice Verifica se um endereco e admin
    function isAdmin(address addr) external view returns (bool) {
        return admins[addr];
    }

    // REGISTRO

    /// @notice Veterinario solicita cadastro (ainda sem aprovacao)
    /// @dev Armazena com status PENDENTE. Contato/localizacao ficam no Supabase.
    function registerVet(
        string calldata nome,
        string calldata crmv
    ) external {
        require(!hasNFT[msg.sender], "Carteira ja possui credencial");
        require(
            vets[msg.sender].status == StatusCredencial.INEXISTENTE,
            "Solicitacao ja existe"
        );
        require(bytes(nome).length > 0, "Nome invalido");
        require(bytes(crmv).length > 0, "CRMV invalido");

        vets[msg.sender] = Vet({
            nome: nome,
            crmv: crmv,
            consultaPrice: 0,
            diariaInternacaoPrice: 0,
            status: StatusCredencial.PENDENTE,
            tokenId: 0
        });

        emit VetSolicitado(msg.sender, nome, crmv);
    }

    // APROVACAO

    /// @notice Owner ou admin aprova um vet pendente e minta o NFT
    /// @dev O evento VetRegistrado inclui `aprovadoPor` para rastreabilidade.
    ///      Qualquer admin pode aprovar individualmente — sem votacao.
    /// @param vetAddress endereco do vet a ser aprovado
    function approveVet(address vetAddress) external onlyOwnerOrAdmin {
        require(!hasNFT[vetAddress], "Ja aprovado");
        require(
            vets[vetAddress].status == StatusCredencial.PENDENTE,
            "Vet nao pendente"
        );

        _mintVet(vetAddress);
    }

    /// @notice Owner ou admin cadastra e aprova um vet em uma unica transacao
    /// @dev Util para cadastros manuais. O evento registra quem aprovou.
    function registerVetByAdmin(
        address vetAddress,
        string calldata nome,
        string calldata crmv
    ) external onlyOwnerOrAdmin {
        require(vetAddress != address(0), "Endereco invalido");
        require(!hasNFT[vetAddress], "Ja aprovado");
        require(
            vets[vetAddress].status == StatusCredencial.INEXISTENTE ||
            vets[vetAddress].status == StatusCredencial.PENDENTE,
            "Carteira ja usada"
        );
        require(bytes(nome).length > 0, "Nome invalido");
        require(bytes(crmv).length > 0, "CRMV invalido");

        vets[vetAddress] = Vet({
            nome: nome,
            crmv: crmv,
            consultaPrice: 0,
            diariaInternacaoPrice: 0,
            status: StatusCredencial.PENDENTE,
            tokenId: 0
        });

        _mintVet(vetAddress);
    }

    // SUSPENSAO

    /// @notice Owner ou admin suspende a credencial de um vet
    /// @dev O evento VetSuspenso inclui `suspensoPor` para rastreabilidade.
    ///      A suspensao pode ser revertida posteriormente via reactivateVet,
    ///      que devolve o status para ATIVA mantendo o mesmo NFT.
    function suspendVet(address vetAddress) external onlyOwnerOrAdmin {
        require(hasNFT[vetAddress], "Vet inexistente");
        require(
            vets[vetAddress].status == StatusCredencial.ATIVA,
            "Credencial nao esta ativa"
        );

        vets[vetAddress].status = StatusCredencial.SUSPENSA;

        emit VetSuspenso(
            vetAddress,
            vets[vetAddress].crmv,
            vets[vetAddress].tokenId,
            msg.sender
        );
    }

    // PRECOS

    /// @notice Vet ativo define seus precos de consulta e internacao (em wei)
    function setPrices(
        uint256 consultaPrice,
        uint256 diariaInternacaoPrice
    ) external {
        require(
            hasNFT[msg.sender] &&
            vets[msg.sender].status == StatusCredencial.ATIVA,
            "Apenas vets ativos"
        );

        vets[msg.sender].consultaPrice = consultaPrice;
        vets[msg.sender].diariaInternacaoPrice = diariaInternacaoPrice;

        emit PrecosAtualizados(
            msg.sender,
            consultaPrice,
            diariaInternacaoPrice
        );
    }

    // VIEWS

    function isVetActive(address vetAddress) external view returns (bool) {
        return hasNFT[vetAddress] &&
               vets[vetAddress].status == StatusCredencial.ATIVA;
    }

    function getVetPrice(
        address vetAddress,
        uint8 tipo,
        uint256 diasInternacao
    ) external view returns (uint256) {
        Vet memory vet = vets[vetAddress];

        if (tipo == 0 || tipo == 1 || tipo == 3 || tipo == 4) {
            return vet.consultaPrice;
        }

        if (tipo == 2) {
            return vet.diariaInternacaoPrice * diasInternacao;
        }

        revert("Tipo invalido");
    }

    function getVet(address vetAddress) external view returns (Vet memory) {
        return vets[vetAddress];
    }

    /// @dev Retorna a lista inteira. Busca por cidade/bairro fica no front-end
    ///      (Supabase + filtros), pois esses dados vivem off-chain.
    function getAllVets() external view returns (address[] memory) {
        return _vetList;
    }
        /// @notice Owner ou admin reativa a credencial de um vet suspenso
    /// @dev Exige que o vet possua NFT e esteja com status SUSPENSA.
    ///      Devolve o status para ATIVA sem mintar novo token (reaproveita o NFT existente).
    /// @param vetAddress endereco do vet a ser reativado
    function reactivateVet(address vetAddress) external onlyOwnerOrAdmin {
    function reactivateVet(address vetAddress) external onlyOwnerOrAdmin {
        require(hasNFT[vetAddress], "Vet inexistente");
        require(
            vets[vetAddress].status == StatusCredencial.SUSPENSA,
            "Credencial nao esta suspensa"
        );

        vets[vetAddress].status = StatusCredencial.ATIVA;
    }
    // INTERNAL

    /// @notice Minta o NFT e registra quem aprovou (msg.sender)
    function _mintVet(address vetAddress) internal {
        _tokenIdCounter++;

        uint256 tokenId = _tokenIdCounter;

        _safeMint(vetAddress, tokenId);

        vets[vetAddress].status = StatusCredencial.ATIVA;
        vets[vetAddress].tokenId = tokenId;

        hasNFT[vetAddress] = true;
        _vetList.push(vetAddress);

        emit VetRegistrado(
            vetAddress,
            vets[vetAddress].nome,
            vets[vetAddress].crmv,
            tokenId,
            msg.sender  // quem aprovou — rastreabilidade
        );
    }
}
