
{config, "{{ base_dir }}/resources/systest_cli.config"}.
{config, "{{ base_dir }}/resources/systest_nodes.config"}.
{config, "{{ base_dir }}/resources/systest_supervision.config"}.

{alias, test, "{{ base_dir }}/ebin"}.
{suites, test, [systest_cli_SUITE,
                systest_node_SUITE,
                systest_supervision_SUITE]}.

{event_handler, systest_event}.
{ct_hooks, [cth_log_redirect,
            {systest_supervision_cth, [], 0},
            {systest_cth, [], 1000}]}.
{enable_builtin_hooks, true}.
