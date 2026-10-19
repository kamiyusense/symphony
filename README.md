# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](https://player.vimeo.com/video/1186371009?h=5626e4b899)

_In this [demo video](https://player.vimeo.com/video/1186371009?h=5626e4b899), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).

Local Linux command shutdown/recovery and preservation requirements are documented in [the Elixir run instructions](elixir/README.md#local-linux-command-lifetime). No unattended-production approval is implied.

### Verification scope

The Elixir implementation separates Portable quality (`make -C elixir --keep-going
portable-ci`) from the required real-Linux isolation gate (`make -C elixir
os-isolation`). The complete gate remains `make -C elixir all`. A Portable GitHub
check cannot certify OS recovery, tracker redispatch, cloud interruption, or
unattended production readiness. See the Elixir README for prerequisites and scope.

Active-turn stops additionally require a scoped App Server interruption response
and matching interrupted terminal event, followed by independent local owned-process
cleanup. Unconfirmed turns retain a durable redispatch barrier; see
[formal active-turn interruption](elixir/README.md#formal-active-turn-interruption).
Model-free evidence does not establish real cloud cancellation.
