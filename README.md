# SaldoLeveApp — iOS

Repositório público do aplicativo nativo SaldoLeve para iPhone, escrito em SwiftUI, com extensão WidgetKit e testes usando dados sintéticos. Contém somente o cliente iOS e sua compilação. O backend PHP, o banco de dados, os anexos e as credenciais da instalação não fazem parte deste repositório.

## Compilar no GitHub

Em Actions → Compilar SaldoLeve iOS, execute Run workflow. Por padrão, o runner xcode-27 compila para iPhone físico ARM64, executa os testes dos modelos e de sincronização e inspeciona o IPA. O artefato SaldoLeve-IPA-AltStore contém SaldoLeve-unsigned.ipa.

Marque run_ui_tests quando precisar validar a interface: a seleção atual cobre salvar/reabrir a visibilidade de Pendências do mês e o grupo recolhido de filtros de tarefas. full_ui_tests executa a bateria completa, incluindo widgets na Tela de Início, contatos e gestos. Quando selecionados, esses testes precisam passar antes da publicação do artefato. Ajuste a seleção ao mudar outros fluxos. A geração comum não recompila o simulador; ela reaproveita o cache do Xcode quando disponível.

A compilação não recebe senha Apple, certificado ou perfil de provisionamento. Instale o IPA com seu instalador de sideload e sua própria conta Apple. A assinatura gratuita precisa ser renovada. O app exige uma instalação compatível do backend e um login válido nessa instalação.

Na versão 2.5.6, tarefas oferecem ordenação por prazo, cadastro recente ou antigo, alteração, alfabeto A–Z/Z–A e ordem manual. O período pode considerar prazo, cadastro ou alteração, com intervalos prontos ou datas personalizadas. Use como padrão salva a escolha na conta. Tudo é o primeiro atalho e a aba inicial. Envie primeiro o backend 2.5.6 para persistir as novas preferências. A geração padrão valida os modelos e o IPA, sem executar o simulador.

## Widgets

A partir da versão 2.5.3, todas as preferências do app estão em Configurações, separadas por categorias e com busca. No iOS 27 ou posterior, a galeria também oferece SaldoLeve · Lista ampliada, uma identidade própria para adicionar diretamente o widget vertical, inclusive quando uma instância antiga não troca de tamanho. O conteúdo é uma lista com subtotais de quantidade; é possível escolher até 30 linhas, respeitando o espaço disponível. A compilação verifica a instalação do tamanho vertical na Tela de Início, além de abrir o menu.

O código de conexão do widget é gerado na conta do usuário, nunca fica nos arquivos de compilação e não deve ser publicado em issues, logs ou capturas.

## Verificação local em um Mac

Use Xcode 27 ou superior. Execute `bash ios/scripts/build-unsigned.sh` para os testes de modelos/sincronização e para o IPA, e `bash ios/scripts/preview-simulator.sh` para as interações. Em Windows, use o GitHub Actions. O projeto pode ser recriado com `node ios/scripts/generate-project.cjs`.
