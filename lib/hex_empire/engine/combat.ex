defmodule HexEmpire.Engine.Combat do
  @moduledoc """
  Port of original/combat.js — deterministic SWF combat, ties to the defender.

      baseAttack   = attacker.count + attacker.morale
      baseDefence  = defender.count + defender.morale
      luck         = battleLuck rule ? nextInt(99)+1 per side : 0
      attackPower  = baseAttack + attackLuck
      defencePower = baseDefence + defenceLuck

      attacker wins iff attackPower > defencePower:
        losing party's EVERY army: morale -= floor(loserArmy.count / 10)
        winner.count  = max(1, winner.count - floor(loserPower/winnerPower * attacker.count))
        winner.morale = min(winner.morale, winner.count)

  Note the defeated-defender case subtracts floor(attackPower/defencePower *
  attacker.count) — proportional to the ATTACKER's count in both branches,
  exactly as the original does.
  """

  alias HexEmpire.Engine
  alias HexEmpire.Engine.{Army, Config, Morale, Rng}

  @typedoc "A battle outcome (powers/luck are diagnostic; ties go to the defender)."
  @type result :: %{
          winner: :attacker | :defender,
          attack_power: integer(),
          defence_power: integer(),
          attack_luck: non_neg_integer(),
          defence_luck: non_neg_integer()
        }

  @doc """
  Resolve combat between two army structs.

  Returns `{game, attacker', defender', result}` where `result` is
  `%{winner: :attacker | :defender, attack_power: _, defence_power: _,
  attack_luck: _, defence_luck: _}`. The caller (Actions.move_army) is
  responsible for removing the annihilated loser and placing the winner.
  Party-wide morale loss is applied to the game here, mirroring the original.

  Load-bearing porting equivalence (do not "fix"): in the defender-wins
  branch, `Morale.add_for_all` cannot reach the in-flight attacker itself,
  because Actions.move_army already cleared the origin field (put_army nil),
  removing the attacker's id from army_pos. In the JS original the discarded
  attacker OBJECT is still referenced in game.armies[party] and DOES get
  mutated by addMoraleForAll — but that mutation is unobservable because the
  object is discarded. Likewise the doomed defender in the attacker-wins
  branch is mutated on-board by add_for_all here, then overwritten by the
  winner in Actions. Also note the party-wide hit uses the loser's PRE-battle
  count. "Fixing" add_for_all or the put_army ordering would silently break
  the golden replays.
  """
  @spec resolve(Engine.game(), Army.t(), Army.t()) ::
          {Engine.game(), Army.t(), Army.t(), result()}
  def resolve(game, attacker, defender) do
    base_attack = attacker.count + attacker.morale
    base_defence = defender.count + defender.morale

    {attack_luck, game} = luck(game)
    {defence_luck, game} = luck(game)

    attack_power = base_attack + attack_luck
    defence_power = base_defence + defence_luck

    if attack_power > defence_power do
      game = Morale.add_for_all(game, -div(defender.count, 10), defender.party)

      count =
        max(1, attacker.count - trunc(:math.floor(defence_power / attack_power * attacker.count)))

      attacker = %{attacker | count: count, morale: min(attacker.morale, count)}

      {game, attacker, defender,
       %{
         winner: :attacker,
         attack_power: attack_power,
         defence_power: defence_power,
         attack_luck: attack_luck,
         defence_luck: defence_luck
       }}
    else
      game = Morale.add_for_all(game, -div(attacker.count, 10), attacker.party)

      count =
        max(1, defender.count - trunc(:math.floor(attack_power / defence_power * attacker.count)))

      defender = %{defender | count: count, morale: min(defender.morale, count)}

      {game, attacker, defender,
       %{
         winner: :defender,
         attack_power: attack_power,
         defence_power: defence_power,
         attack_luck: attack_luck,
         defence_luck: defence_luck
       }}
    end
  end

  defp luck(game) do
    if Config.has_rule?(game, :battle_luck) do
      {v, rng} = Rng.next_int(game.rng, 99)
      {v + 1, %{game | rng: rng}}
    else
      {0, game}
    end
  end
end
