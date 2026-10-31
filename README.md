# SaldoLeveApp — iOS

Repositório público do aplicativo nativo SaldoLeve para iPhone, escrito em SwiftUI, com extensão WidgetKit e testes usando dados sintéticos. Contém somente o cliente iOS e sua compilação. O backend PHP, o banco de dados, os anexos e as credenciais da instalação não fazem parte deste repositório.

## Compilar no GitHub

Em Actions → Compilar SaldoLeve iOS, execute Run workflow. Por padrão, o runner xcode-27 compila para iPhone físico ARM64, executa os testes dos modelos e de sincronização e inspeciona o IPA. O artefato SaldoLeve-IPA-AltStore contém SaldoLeve-unsigned.ipa.

Marque run_ui_tests quando precisar validar a interface: a seleção atual cobre o widget (opções, simulador e instalação do vertical na Tela de Início), a central de Configurações, a conclusão e importação de aniversariantes e o pagamento de parcelas em Mais opções. full_ui_tests executa a bateria completa, incluindo widgets na Tela de Início, contatos e gestos. Quando selecionados, esses testes precisam passar antes da publicação do artefato. Ajuste a seleção ao mudar outros fluxos. A geração comum não recompila o simulador; ela reaproveita o cache do Xcode quando disponível.

A compilação não recebe senha Apple, certificado ou perfil de provisionamento. Instale o IPA com seu instalador de sideload e sua própria conta Apple. A assinatura gratuita precisa ser renovada. O app exige uma instalação compatível do backend e um login válido nessa instalação.

Na versão 2.7.0, o widget ganha opções de aparência (cor, fundo, marcador, separadores, contagens) e um simulador fixo; aniversariantes podem ser concluídos, ter avisos persistentes e sincronizar com os Contatos; a Siri cria tarefas (“me avise de … daqui 2 horas”); o ícone oferece Nova tarefa e Suspender avisos; e há lembretes por local ao chegar ou sair de lugares salvos. Envie primeiro o backend 2.7.0 (API 7).

Na versão 2.6.0, as abas principais passam a ser Despesas (com o mês em aberto, resumos, filtros e cards) e Agenda. Configurações → Layout traz um simulador ao vivo para Despesas, Agenda, tarefa aberta e widgets, além de quatro estilos personalizáveis para tarefas com muitas subtarefas. O widget abre direto a Agenda, sem mini cards, e o formato vertical usa toda a altura. Envie primeiro o backend 2.6.0 para salvar os novos layouts. A geração padrão valida os modelos e o IPA, sem executar o simulador.

## Widgets

A partir da versão 2.5.3, todas as preferências do app estão em Configurações, separadas por categorias e com busca. No iOS 27 ou posterior, a galeria também oferece SaldoLeve · Lista ampliada, uma identidade própria para adicionar diretamente o widget vertical, inclusive quando uma instância antiga não troca de tamanho. O conteúdo é uma lista agrupada por prazo, sem mini cards; o formato vertical usa toda a altura (até 30 linhas) e o toque abre a Agenda do app. A compilação verifica a instalação do tamanho vertical na Tela de Início, além de abrir o menu.

O código de conexão do widget é gerado na conta do usuário, nunca fica nos arquivos de compilação e não deve ser publicado em issues, logs ou capturas.

## Verificação local em um Mac

Use Xcode 27 ou superior. Execute `bash ios/scripts/build-unsigned.sh` para os testes de modelos/sincronização e para o IPA, e `bash ios/scripts/preview-simulator.sh` para as interações. Em Windows, use o GitHub Actions. O projeto pode ser recriado com `node ios/scripts/generate-project.cjs`.
