// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/VetNFT.sol";
import "../src/PetFactory.sol";
import "../src/PetContract.sol";

/// @title MockV3Aggregator - Feed Chainlink falso para uso em testes
/// @notice Finge ser um AggregatorV3Interface, retornando um preco fixo.
/// @dev Necessario porque em rede local nao existe Chainlink de verdade.
///      Sem isso, qualquer teste que chame converterParaReais reverteria.
contract MockV3Aggregator {
    int256 public answer;

    constructor(int256 _answer) {
        answer = _answer;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        // Retorna apenas o preco; os demais campos do round nao sao usados pelo PetContract
        return (0, answer, 0, 0, 0);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }
}

/// @title PetgreeChainTest - Testes dos fluxos principais da plataforma
/// @notice Cobre credenciamento de vets, registro de pets, consultas, vacinacao,
///         atestados, memorial, suspensao/reativacao de vets e conversao de precos.
contract PetgreeChainTest is Test {
    VetNFT  vetNFT;
    PetFactory factory;
    MockV3Aggregator ethUsdFeed;
    MockV3Aggregator brlUsdFeed;

    // Atores do teste
    address owner = address(this); // o proprio contrato de teste e o deployer/owner
    address tutor = address(0x1);
    address vet   = address(0x2);
    address vet2  = address(0x3);

    // Precos de exemplo (em wei) que o vet vai configurar
    uint256 constant PRECO_CONSULTA = 0.01 ether;
    uint256 constant PRECO_DIARIA   = 0.005 ether;

    // ─────────────────────────────────────────────
    //  SETUP - roda antes de cada teste
    // ─────────────────────────────────────────────
    function setUp() public {
        // Cria os feeds mock. ETH/USD = 2000.00000000, BRL/USD = 0.20000000
        // (8 casas decimais, como os feeds reais da Chainlink)
        ethUsdFeed = new MockV3Aggregator(2000 * 1e8);
        brlUsdFeed = new MockV3Aggregator(0.2 * 1e8);

        vetNFT = new VetNFT();

        factory = new PetFactory(
            address(vetNFT),
            address(ethUsdFeed),
            address(brlUsdFeed)
        );
    }

    // ─────────────────────────────────────────────
    //  HELPERS - funcoes auxiliares reaproveitadas nos testes
    // ─────────────────────────────────────────────

    /// @dev Cadastra, aprova e define precos de um vet. Retorna pronto para atender.
    function _criarVetAtivo(address vetAddr) internal {
        // O vet solicita o cadastro (status PENDENTE)
        vm.prank(vetAddr);
        vetNFT.registerVet("Dr. Teste", "CRMV-123");

        // O owner aprova o vet pendente e minta o NFT
        vetNFT.approveVet(vetAddr);

        // O vet define seus proprios precos (precisa ser ele mesmo a chamar)
        vm.prank(vetAddr);
        vetNFT.setPrices(PRECO_CONSULTA, PRECO_DIARIA);
    }

    /// @dev Registra um pet pelo tutor e devolve o PetContract ja tipado.
    function _criarPet() internal returns (PetContract) {
        vm.prank(tutor);
        address petAddr = factory.registerPet(
            "Rex",
            "Vira-lata",
            block.timestamp,
            address(0), // sem pai
            address(0)  // sem mae
        );
        return PetContract(petAddr);
    }

    // ─────────────────────────────────────────────
    //  TESTES DE DEPLOY
    // ─────────────────────────────────────────────

    function testDeployFuncionando() public view {
        assertTrue(address(vetNFT) != address(0));
        assertTrue(address(factory) != address(0));
    }

    function testDeployerEhAdmin() public view {
        // O deployer do VetNFT deve ser admin automaticamente (definido no constructor)
       assertTrue(vetNFT.admins(owner));
    }

    // ─────────────────────────────────────────────
    //  TESTES DE CREDENCIAL DE VET
    // ─────────────────────────────────────────────

    function testRegistrarEAprovarVet() public {
        _criarVetAtivo(vet);
        // Apos aprovacao, o vet deve estar ativo
        assertTrue(vetNFT.isVetActive(vet));
    }

    function testVetNaoAprovadoNaoEstaAtivo() public {
        // Vet apenas solicitou, ainda nao foi aprovado
        vm.prank(vet);
        vetNFT.registerVet("Dr. Sem Aprovacao", "CRMV-999");
        assertFalse(vetNFT.isVetActive(vet));
    }

    function testNaoTutorNaoPodeAprovarVet() public {
        // Primeiro o vet solicita
        vm.prank(vet);
        vetNFT.registerVet("Dr. Teste", "CRMV-123");

        // Um endereco que nao e owner nem admin tenta aprovar -> deve reverter
        vm.prank(tutor);
        vm.expectRevert("Apenas owner ou admin");
        vetNFT.approveVet(vet);
    }

    function testCredencialEhSoulbound() public {
        _criarVetAtivo(vet);
        uint256 tokenId = vetNFT.getVet(vet).tokenId;

        // Tentar transferir a credencial deve reverter (soulbound)
        vm.prank(vet);
        vm.expectRevert("VetNFT: soulbound, nao transferivel");
        vetNFT.transferFrom(vet, vet2, tokenId);
    }

    function testSuspenderEReativarVet() public {
        _criarVetAtivo(vet);

        // Owner suspende
        vetNFT.suspendVet(vet);
        assertFalse(vetNFT.isVetActive(vet));

        // Owner reativa
        vetNFT.reactivateVet(vet);
        assertTrue(vetNFT.isVetActive(vet));
    }

    // ─────────────────────────────────────────────
    //  TESTES DE REGISTRO DE PET
    // ─────────────────────────────────────────────

    function testRegistrarPet() public {
        PetContract pet = _criarPet();

        assertEq(pet.nome(), "Rex");
        assertEq(pet.dono(), tutor);
        assertEq(factory.totalPets(), 1);
        assertTrue(factory.isPetRegistered(address(pet)));
    }

    function testPedigreeInvalidoReverte() public {
        // Tentar registrar com um "pai" que nao e um PetContract desta factory
        vm.prank(tutor);
        vm.expectRevert("Pai invalido: nao e um PetContract registrado nesta factory");
        factory.registerPet(
            "Filhote",
            "Vira-lata",
            block.timestamp,
            address(0xDEAD), // pai invalido
            address(0)
        );
    }

    function testPedigreeValido() public {
        // Cria o pai primeiro
        PetContract pai = _criarPet();

        // Registra um filhote apontando para o pai legitimo
        vm.prank(tutor);
        address filhote = factory.registerPet(
            "Filhote",
            "Vira-lata",
            block.timestamp,
            address(pai),
            address(0)
        );

        assertEq(PetContract(filhote).pai(), address(pai));
    }

    // ─────────────────────────────────────────────
    //  TESTES DE CONSULTA
    // ─────────────────────────────────────────────

    function testAbrirConsulta() public {
        _criarVetAtivo(vet);
        PetContract pet = _criarPet();

        // O tutor (dono) abre uma consulta comum
        vm.prank(tutor);
        pet.openConsultation(vet, PetContract.TipoConsulta.CONSULTA, 0);

        assertEq(pet.totalConsultas(), 1);
    }

    function testApenasDonoAbreConsulta() public {
        _criarVetAtivo(vet);
        PetContract pet = _criarPet();

        // Um endereco que nao e o dono tenta abrir consulta -> reverte
        vm.prank(vet);
        vm.expectRevert("Apenas o dono");
        pet.openConsultation(vet, PetContract.TipoConsulta.CONSULTA, 0);
    }

    function testInternacaoExigeDiarias() public {
        _criarVetAtivo(vet);
        PetContract pet = _criarPet();

        // Internacao com 0 diarias deve reverter
        vm.prank(tutor);
        vm.expectRevert("Informe as diarias");
        pet.openConsultation(vet, PetContract.TipoConsulta.INTERNACAO, 0);
    }

    function testFluxoVacinacaoCompleto() public {
        _criarVetAtivo(vet);
        PetContract pet = _criarPet();

        // Tutor abre uma consulta de vacinacao
        vm.prank(tutor);
        pet.openConsultation(vet, PetContract.TipoConsulta.VACINACAO, 0);

        // Vet adiciona o registro publico (lote da vacina)
        vm.prank(vet);
        pet.addRecord(1, "Vacina V10 - lote ABC123");

        // Vet finaliza a consulta
        vm.prank(vet);
        pet.finalizeConsultation(1);

        // Confere o status finalizado
        (, , , , , , , PetContract.StatusConsulta status) = pet.consultas(0);
        assertEq(uint256(status), uint256(PetContract.StatusConsulta.FINALIZADA));
    }

    function testVacinacaoNaoFinalizaSemRegistro() public {
        _criarVetAtivo(vet);
        PetContract pet = _criarPet();

        vm.prank(tutor);
        pet.openConsultation(vet, PetContract.TipoConsulta.VACINACAO, 0);

        // Tentar finalizar sem adicionar o registro da vacina -> reverte
        vm.prank(vet);
        vm.expectRevert("Adicione a vacina antes de finalizar");
        pet.finalizeConsultation(1);
    }

    // ─────────────────────────────────────────────
    //  TESTES DE ATESTADO
    // ─────────────────────────────────────────────

    function testEmitirAtestado() public {
        _criarVetAtivo(vet);
        PetContract pet = _criarPet();

        vm.prank(vet);
        pet.issueAtestado("Pet saudavel, apto para viagem.");

        assertEq(pet.getAtestados().length, 1);
    }

    // ─────────────────────────────────────────────
    //  TESTES DE MEMORIAL
    // ─────────────────────────────────────────────

    function testMemorialExigeVacinacao() public {
        _criarVetAtivo(vet);
        PetContract pet = _criarPet();

        // Sem nenhuma vacinacao registrada, marcar como falecido deve reverter
        vm.prank(tutor);
        vm.expectRevert("Memorial exige vacinacao registrada");
        pet.markAsDeceased("Bom companheiro", block.timestamp);
    }

    function testMemorialComVacinacao() public {
        _criarVetAtivo(vet);
        PetContract pet = _criarPet();

        // Registra uma vacinacao completa primeiro
        vm.prank(tutor);
        pet.openConsultation(vet, PetContract.TipoConsulta.VACINACAO, 0);
        vm.prank(vet);
        pet.addRecord(1, "Vacina V10 - lote ABC123");
        vm.prank(vet);
        pet.finalizeConsultation(1);

        // Agora o memorial deve funcionar
        vm.prank(tutor);
        pet.markAsDeceased("Foi um grande amigo.", block.timestamp);

        assertTrue(pet.falecido());
    }

    function testPetFalecidoBloqueiaNovasConsultas() public {
        _criarVetAtivo(vet);
        PetContract pet = _criarPet();

        // Prepara vacinacao e marca como falecido
        vm.prank(tutor);
        pet.openConsultation(vet, PetContract.TipoConsulta.VACINACAO, 0);
        vm.prank(vet);
        pet.addRecord(1, "Vacina V10");
        vm.prank(vet);
        pet.finalizeConsultation(1);
        vm.prank(tutor);
        pet.markAsDeceased("Descanse em paz.", block.timestamp);

        // Tentar abrir nova consulta apos o falecimento -> reverte
        vm.prank(tutor);
        vm.expectRevert("Pet falecido: historico encerrado");
        pet.openConsultation(vet, PetContract.TipoConsulta.CONSULTA, 0);
    }

    // ─────────────────────────────────────────────
    //  TESTES DE PRECO / CHAINLINK
    // ─────────────────────────────────────────────

    function testConversaoParaReais() public {
        _criarVetAtivo(vet);
        PetContract pet = _criarPet();

        vm.prank(tutor);
        pet.openConsultation(vet, PetContract.TipoConsulta.CONSULTA, 0);

        // PRECO_CONSULTA = 0.01 ETH. Com ETH=US$2000 e BRL=US$0.20:
        // 0.01 ETH = US$20 = R$100. Confere a conversao via Chainlink (mock).
        (uint256 reais, ) = pet.getPrecoConsultaEmReais(1);
        assertEq(reais, 100);
    }
}
