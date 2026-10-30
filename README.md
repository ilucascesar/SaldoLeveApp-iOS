# SaldoLeveApp — iOS

Repositório público do aplicativo nativo SaldoLeve para iPhone, escrito em SwiftUI, com extensão WidgetKit e testes usando dados sintéticos. Contém somente o cliente iOS e sua compilação. O backend PHP, o banco de dados, os anexos e as credenciais da instalação não fazem parte deste repositório.

## Compilar no GitHub

Em Actions → Compilar SaldoLeve iOS, execute Run workflow. O runner padrão xcode-27 compila para iPhone físico ARM64, executa os testes dos modelos e de sincronização e confere as telas no simulador. Somente depois dos testes e da inspeção do IPA, o artefato SaldoLeve-IPA-AltStore fica disponível. Ele contém SaldoLeve-unsigned.ipa.

A compilação não recebe senha Apple, certificado ou perfil de provisionamento. Instale o IPA com seu instalador de sideload e sua própria conta Apple. A assinatura gratuita precisa ser renovada. O app exige uma instalação compatível do backend e um login válido nessa instalação.

Na versão 2.5.4, a Visão geral permite ocultar Pendências do mês sem confundir cancelamentos de consulta com falta de conexão. Os padrões de aniversário podem ser aplicados a todos os cadastros, com personalização individual posterior; envie primeiro a atualização correspondente do backend.

## Widgets

A partir da versão 2.5.3, todas as preferências do app estão em Configurações, separadas por categorias e com busca. No iOS 27 ou posterior, a galeria também oferece SaldoLeve · Lista ampliada, uma identidade própria para adicionar diretamente o widget vertical, inclusive quando uma instância antiga não troca de tamanho. O conteúdo é uma lista com subtotais de quantidade; é possível escolher até 30 linhas, respeitando o espaço disponível. A compilação verifica a instalação do tamanho vertical na Tela de Início, além de abrir o menu.

O código de conexão do widget é gerado na conta do usuário, nunca fica nos arquivos de compilação e não deve ser publicado em issues, logs ou capturas.

## Verificação local em um Mac

Use Xcode 27 ou superior. Execute `bash ios/scripts/build-unsigned.sh` para os testes de modelos/sincronização e para o IPA, e `bash ios/scripts/preview-simulator.sh` para as interações. Em Windows, use o GitHub Actions. O projeto pode ser recriado com `node ios/scripts/generate-project.cjs`.
