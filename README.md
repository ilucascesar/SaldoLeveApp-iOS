# SaldoLeve para iPhone

Cliente SwiftUI do SaldoLeve com extensões WidgetKit e Compartilhar.

## Versão 2.12.0

A ação Proteger é a primeira ao deslizar da direita para a esquerda, seguida de Lixeira. O menu dentro da tarefa permite aplicar um modelo compacto em todas as subtarefas, com exceções individuais. Nome, data e presença de anexo permanecem visíveis. A personalização mostra apenas as opções da área escolhida no simulador.

A repetição tem botão próprio com intervalos de um, seis ou doze meses e configuração personalizada. Observações discretas acompanham cada subtarefa e as permissões da tarefa compartilhada.


Tarefas protegidas permanecem identificáveis em Tudo. A abertura pede Face ID ou a senha escrita de cada tarefa. O cliente oculta descrição, subtarefas e valores até o desbloqueio. Deslize a tarefa e use Proteger ou toque no cadeado dentro dela. A recuperação exige a senha escrita da conta e define uma nova senha sem apagar conteúdo.

Novidades mostra as melhorias desta versão do iPhone; Não mostrar novamente vale para a versão atual e pode ser revisto em Configurações.

O editor tenta concluir o envio ao alternar de aplicativo. Notificações abrem a subtarefa correspondente. A atualização oportunista em segundo plano recalcula os avisos, respeitando o agendamento do iOS. O widget solicita atualização ao alterar a proteção e apresenta indisponibilidade quando a conexão falha.

As gravações financeiras conferem a versão do registro. Os layouts e a exportação das tarefas mantêm compatibilidade com o servidor 2.12.0. O app usa a instalação em https://tools.ilucas.com.br/SaldoLeve/.

## Compilação

O workflow Compilar SaldoLeve iOS gera o IPA ARM64, executa os testes de modelos e sincronização e inspeciona o pacote. A geração padrão usa o cache do Xcode. Os testes de simulador são opcionais pelos parâmetros run_ui_tests e full_ui_tests.

O artefato SaldoLeve-IPA-AltStore contém o IPA sem assinatura. Instale com o assinador de sua preferência e sua conta Apple.

Este repositório contém apenas o cliente nativo e recursos revisados. O servidor, o banco, os comprovantes e as credenciais ficam na instalação privada.
