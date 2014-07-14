

class SillyQ2TextMode

  Weapon = Struct.new("Q2T_Weapon", :name, :damage_low, :damage_hi, :niter, :nshots, :splash, :is_nuke, :snd)

  Blaster         = Weapon.new("blaster",          5, 10, 1, 0, 0, false, "P'yzssszzzt!")
  Shotgun         = Weapon.new("shotgun",         10, 30, 1,10, 0, false, "*boom*")
  SuperShotgun    = Weapon.new("super shotgun",   25, 35, 1, 5, 0, false, "**BOOM**")
  MachineGun      = Weapon.new("machinegun",       2,  4, 4,10, 0, false, "Rat-a-tat-tat-tat-tat!")
  ChainGun        = Weapon.new("chaingun",         3,  8, 8,20, 0, false, "whirrr-ttt'ttt'ttt'ttt'ttt'ttt'ttt'ttt'ttt")
  GrenadeLauncher = Weapon.new("grenade launcher",30, 50, 1, 5, 1, false, "'FOMP!.........................BOOM!")
  HyperBlaster    = Weapon.new("hyperblaster",     3,  6, 6,15, 0, false, "whine-tzt'tzt'tzt'tzt'tzt'tzt'tzt")
  RocketLauncher  = Weapon.new("rocket launcher", 40, 65, 1, 5, 1, false, "ROARrrr.....................BOOM!!")
  RailGun         = Weapon.new("railgun",        -66,125, 1,10, 0, false, "K'zzzpanggg!!")
  BFG             = Weapon.new("bfg",             60,150, 1, 2, 1, false, "wheezzzzeee-BLAT!!....sizzle....sizzle....sizzle...CRACKLE!!FOMP!")
  Grenades        = Weapon.new("grenades",        40, 60, 1, 5, 1, false, "ker-schl'k........tick......tick.......tick......tick......BOOM!!")
  PotatoeGun      = Weapon.new("potatoe gun",     40, 60, 1, 5, 0, false, ">>FOOOOMP!<<............................SPACK!!")
  Flamethrower    = Weapon.new("flamethrower",    40, 60, 1, 5, 1, false, "ROARrrrrr hissssssssssssssssss crackle......")
  TacticalNuke    = Weapon.new("tactical thermonuclear device",
                                                  1000000, 1000000000, 1, 1, 1, true, "K'tK'KHHKHHKHHKHHHHHHKHHHHSHHHSSHHHSHHHHHHHHKFPHHHHHHHHFFFKFFHFHFHFFHFFHHHHHHFKKFKHFHHHHHHHHSSSHHHHHHHHHHHHFHHHHHHHHHHHHHHHSSSSSSSSSSSSSSHSHSHSHSHSSSSSSSPKKKKKPTTTTPPKKKKKKKHHHHHHHHHHHHSSSSSSHSSSHSSHSSSSSSSSSSKSSKSSKSKKKKKKKKKKKP'P'PKKKKKKKKKKKKKKKTKKKKTKKTKKKKKKKKKSHKKKSHKKKKKKSKKKSKKKSKKKSHHHHHHHHHHHHKKKKKKKKKKKKKKKKHHKKKKKHKSKHKShsssssshshhhhhhhshhhhhhhshhhhhhhshhhhhhshhhhhhshhhhhshhhhhhhshhhhhhhhhhhhhhh...hhhh...hhhhhhhhh.hhhh.hhhs.hhhhsshshhhhhhhhhhhhhhhhhhhhh....hhh.hhhhh......h.h...........h.............h.....................h...........................")

  WeapList = [ Blaster, Shotgun, SuperShotgun, MachineGun,
               ChainGun, GrenadeLauncher, HyperBlaster,
               RocketLauncher, RailGun, BFG, Grenades, 
               PotatoeGun, Flamethrower, TacticalNuke ]

  ItemNameAliases = {
    "bl" => Blaster.name, "sg" => Shotgun.name, "ssg" => SuperShotgun.name,
    "mg" => MachineGun.name, "cg" => ChainGun.name,
    "gl" => GrenadeLauncher.name, "hb" => HyperBlaster.name,
    "rl" => RocketLauncher.name, "rg" => RailGun.name,
    "pineapples" => Grenades.name, "nades" => Grenades.name
  }

  ThinAirName = "thin air"

  SlowNPCActionInterval = 30 # seconds
  FastNPCActionInterval = 12 # seconds

  def initialize(rcon_server, logger)
    @rcon_server, @logger = rcon_server, logger
    @imaginary_players = {}
    @last_player_action_time = Time.at(0).gmtime
    update_action_times(SlowNPCActionInterval)
  end

  def kill(player)
    unless player.dead?
      @logger.log(ANSI.sillyq2_info("#{player.name} killed #{player.genderself}."))
      player.add_score(-1)
      player.kill
    end
  end

  def use(player, item_name)
    update_action_times(FastNPCActionInterval) unless player.npc
    item_name.downcase!
    item_name.strip!
    item_name = ItemNameAliases[item_name] if ItemNameAliases.has_key? item_name
    weap = WeapList.detect {|w| w.name == item_name}
    if weap
      player.set_weap(weap)
    else
      if item_name =~ /\A(WMD|weapon of mass destruction)\z/i
        @logger.log(ANSI.sillyq2_info("ERROR: WMD NOT FOUND.  PLEASE INVADE THE COUNTRY OF YOUR CHOICE."))
      else
        @logger.log(ANSI.sillyq2_info("unknown item: #{item_name}"))
      end
    end
  end

  def shoot(attacker, name)
    return if attacker.dead?
    update_action_times(FastNPCActionInterval) unless attacker.npc
    name.strip!
    died = false
    if attacker.weap.is_nuke
      targets = @rcon_server.active_clients.map {|cl| cl.q2t }
      targets += @imaginary_players.values
    else
      targets = @rcon_server.get_db_clients_by_name(name).map {|cl| cl.q2t }
      targets = [ get_imaginary_player(name) ] if targets.empty?
    end
    if targets.reject {|t| t.dead? }.empty?
      targets = [ get_imaginary_player("") ]
    end
    if name =~ /\b(wall|floor|ceiling|road|highway|street|pavement|tarmac|runway|door|grass|lawn|gravel|asphalt|astroturf|driveway|sidewalk|porch)/i
      targets << attacker if attacker.weap.splash > 0  &&  !targets.include?(attacker)
    end
    @logger.log(ANSI.sillyq2_info("#{attacker.name}: #{attacker.weap.snd}")) if attacker.ammo?
    died = false
    catch(:out_of_ammo) do
      attacker.weap.niter.times do
        targets.each do |target|
          next if target.dead?
          target.set_last_attacker(attacker) unless target == attacker
          if attacker.ammo?  ||  attacker.weap.is_nuke
            handle_shot(attacker, target)
            died ||= target.dead?
          else
            @logger.log(ANSI.sillyq2_info("#{attacker.name}: *CLICK*"))
            throw :out_of_ammo
          end 
        end
      end
    end
    display_scores if died
  end

  def display_scores
    @logger.log("                  name  score     time    fph  status", "")
    @logger.log("------------------------------------------------------------------------------", "")
    real_players = @rcon_server.active_clients.map {|cl| cl.q2t }
    imag_players = @imaginary_players.values
    players = (real_players + imag_players).sort {|a,b| b.score <=> a.score }
    players.each do |player|
      ttl_sec = (Time.now - player.start_time).to_i
      min, sec = ttl_sec / 60, ttl_sec % 60
      fph = player.score / ([ttl_sec, 1].max.to_f / (60 * 60))
      status = if player.dead?
        "#{player.gibbed? ? 'gibbed' : 'killed'}, by #{player.killedby}"
      else
        if player.npc
          player.static ? "existing" : "alive, mad at #{player.last_attacker_name}"
        else
          "alive, with #{player.weap.name}"
        end
      end
      score_str = sprintf("%22s  %5d %5s:%02d %6.1f  %s",
                          player.name, player.score,
                          "%02d" % min, sec, fph, status)
      @logger.log(player.dead? ? ANSI.sillyq2_score_dead(score_str) : score_str, "")
    end
  end

  def kick_imaginary_player(name)
    name.strip!
    hashkey = imaginary_player_hashkey(name)
    if @imaginary_players.has_key? hashkey
      player = @imaginary_players[hashkey]
      @logger.log(ANSI.sillyq2_info("[Dork Buster: #{player.name} was kicked]"))
      @imaginary_players.delete(hashkey)
    end
  end

  def run_npcs
    return if secs_to_next_npc_action >= 1
    npc = pick_npc
    npc = resurrect_npc if !npc && (rand(3) == 0) &&
                            ((Time.now - @last_player_action_time) <
                              FastNPCActionInterval)
    if npc  &&  !npc.static
      target = pick_npc_target(npc)
      if target
        if (rand(2) == 0)
          tauntmsg = npc.get_taunt(target.name)
          @logger.log(ANSI.sillyq2_chat("#{npc.name}: #{tauntmsg}")) if tauntmsg
        end
        new_weap = pick_npc_weap(npc)
        if new_weap != npc.weap  ||  (!npc.ammo? && (rand(2) == 0))
          npc.set_weap(new_weap)
          @logger.log(ANSI.sillyq2_chat("#{npc.name}: use #{npc.weap.name}"))
        end
        @logger.log(ANSI.sillyq2_chat("#{npc.name}: shoot #{target.name}"))
        shoot(npc, target.name)
      end
    end
    resurrect_npc if rand(7) == 0
    update_action_times(angry_npcs.empty? ? SlowNPCActionInterval : FastNPCActionInterval)
  end

  def secs_to_next_npc_action
    [@next_npc_action_time - Time.now, 0].max
  end

  private

  def pick_npc  # may return nil
    npcs = viable_npc_attackers
    angrys = angry_npcs
    if angrys.empty?  ||  rand(7) == 0
      npcs.rndpick
    else
      if rand(7) == 0
        angrys.rndpick
      else
        angrys.sort {|a,b| b.last_attacker_time <=> a.last_attacker_time }[0]
      end
    end
  end

  def resurrect_npc
    lazarus = @imaginary_players.values.select {|npc| npc.dead? }.rndpick
    if lazarus
      lazarus.spawn
      @logger.log(ANSI.sillyq2_info("#{lazarus.name} joined the game."))
    end
    lazarus
  end

  def pick_npc_weap(npc)
    rand(3) == 0 ? WeapList.rndpick : npc.last_attacker_weap
  end

  def pick_npc_target(npc)
    viable = viable_targets.reject {|t| t == npc }
    targ = viable.find {|t| t.name == npc.last_attacker_name }
    if rand(7) == 0  ||  !targ
      targ = viable.rndpick
    end
    targ
  end

  def angry_npcs
    viable_npc_attackers.select {|npc| npc.last_attack_time < npc.last_attacker_time }
  end

  def viable_npc_attackers
    @imaginary_players.values.reject {|npc| npc.dead? || npc.static }
  end

  def viable_targets
    targets = @rcon_server.active_clients.map {|cl| cl.q2t }
    targets += @imaginary_players.values
    targets.reject {|t| t.dead? || t.insubstantial }
  end

  def handle_shot(attacker, target)
    attacker.fire_weap
    dmg = target.calc_damage_from(attacker.weap)
    if dmg > 0
      target.receive_damage(dmg, attacker.weap.is_nuke)
      no_dmg = target.static  &&  target.invuln  &&  !attacker.weap.is_nuke
      if no_dmg
        @logger.log(ANSI.sillyq2_info("#{attacker.name} shoots #{target.name}."))
      else
        @logger.log(ANSI.sillyq2_info("#{target.name}: " + target.get_pain_snd))
      end
      if target.dead?
        @logger.log(ANSI.sillyq2_info("#{target.name} " + (target.gibbed? ? "was gibbed." : "died.")))
        killed_self = (attacker == target)
        target.killedby = killed_self ? attacker.genderself : attacker.name
        attacker.add_score(killed_self ? -1 : 1)
      end
      unless no_dmg
        if (rand(2) == 0)
          whinemsg = target.get_whine(attacker.name)
          @logger.log(ANSI.sillyq2_chat("#{target.name}: #{whinemsg}")) if whinemsg
        end
      end
    else
      miss_type = (target.name == ThinAirName)? "shot at" : "missed"
      @logger.log(ANSI.sillyq2_info("#{attacker.name} #{miss_type} #{target.name}."))
    end
  end

  def get_imaginary_player(name)
    name = ThinAirName if name =~ /\A\s*\z/
    hashkey = imaginary_player_hashkey(name)
    player = (@imaginary_players[hashkey] ||= create_imaginary_player(name))
  end

  def imaginary_player_hashkey(name)
    name.downcase.strip.gsub(/\s{2,}/, " ")
  end

  def create_imaginary_player(name)
    player = SillyQ2TextModeClient.new(name, :neuter)
    player.npc = true
    if name =~ /\b(air|midair|sky|atmosphere|space|clouds|vapor|steam|wall|floor|ceiling|lava|water|ocean|h2o|slime|lake|river|stream|canal|road|highway|street|pavement|tarmac|runway|door|archway|fence|grass|lawn|gravel|asphalt|astroturf|driveway|sidewalk|porch|planet|moon|earth|computer|screen|monitor|keyboard|mailbox)/i
      player.invuln = true
      player.static = true
      if name =~ /\b(air|midair|sky|atmosphere|space|clouds|vapor|steam)/i
        player.insubstantial = true
      end
    end
    player
  end

  def update_action_times(npc_interval)
    @last_player_action_time = Time.now
    @next_npc_action_time = Time.now + (npc_interval / 2) + rand(npc_interval / 2)
  end

end


class SillyQ2TextModeClient
  GIBBED = -25
  GENDER_SELVES = { :male => "himself", :female => "herself", :neuter => "itself" }

  attr_reader :score, :health, :name, :gender, :start_time, :weap,
              :last_attacker_name, :last_attacker_time,
              :last_attacker_weap, :last_attack_time
  attr_accessor :killedby, :npc, :invuln, :static, :insubstantial

  def initialize(name, gender)
    @name, @gender = name, gender
    @npc = false
    @invuln = false
    @static = false
    @insubstantial = false
    @last_attacker = ""
    @last_attacker_time = Time.at(0).gmtime
    @last_attacker_weap = SillyQ2TextMode::Blaster
    @score = 0
    @start_time = Time.now
    spawn
  end

  def spawn
    @health = 100
    @killedby = ""
    @shots_left = Hash.new(0)
    @last_attack_time = Time.at(0).gmtime
    set_weap(SillyQ2TextMode::Blaster)
  end

  def kill
    @health = 0 unless dead?
  end
  
  def receive_damage(amnt, force=false)
    @health -= amnt unless @invuln && !force
  end

  def calc_damage_from(weap)
    return 0 if insubstantial  &&  !weap.is_nuke
    dl, dh = weap.damage_low, weap.damage_hi
    if dl < 0
      dl = dl.abs
      return 0 if rand(100) > dl
    end
    dl + rand((dh - dl) + 1)
  end

  def add_score(amnt)
    @score += amnt
  end
  
  def set_weap(weap)
    @weap = weap
    restock_ammo = (! @shots_left.has_key?(@weap.name))  ||
                    (@shots_left[weap.name] < 1)
    @shots_left[weap.name] = weap.nshots if restock_ammo
  end    

  def fire_weap
    @last_attack_time = Time.now
    @shots_left[@weap.name] -= 1 if @shots_left[@weap.name] > 0
  end

  def set_last_attacker(attacker)
    @last_attacker_name = attacker.name
    @last_attacker_time = Time.now
    @last_attacker_weap = attacker.weap
  end

  def ammo?; (@weap.nshots == 0) || (@shots_left[@weap.name] > 0); end
  def dead?; @health <= 0; end
  def gibbed?; @health < GIBBED; end
  def genderself; GENDER_SELVES[@gender]; end

  def get_pain_snd
    snd = (@name =~ /flanders|\bned\b/i) ? ["Diddely ", "Doodely "].rndpick : ""
    snd << case @health
      when (75..9999999) then ["Ooh!", "Aah!", "Uf!"].rndpick
      when (50..74)      then ["Auuugh!", "Ooooffff!"].rndpick
      when (25..49)      then ["Arrrrrrrrrgh!", "Urrrrrrrrrrgh!"].rndpick
      when (1..24)       then ["Urrrrrrrrrrrrrgnnp!", "Auuuugggggghrhrhhhhhrrrggg!"].rndpick
      when (GIBBED..0)   then ["Wahghhhhhhhllgrllahhhppphhhhhhhhhhhhhhhh...", "Arrrrgggllphhhhhllahaaaaahhhhhaaahhhhhh..."].rndpick
      when (-99999999999999999999..(GIBBED - 1)) then "Gl'tkthcktp'p'tck'pthkplllpkptpdpt!"
    end
    snd[0] = "D'o" if @name =~ /homer/i
    snd[-1] = ", man!" if @name =~ /bart/i
    snd
  end

  def get_taunt(target_name)
    tauntmsg = nil
    if @name =~ /sicker/i
      tauntmsg = "#{target_name}, i'm gonna put a gun in your mouth!"
    end
    tauntmsg
  end

  def get_whine(attacker_name)
    whinemsg = nil
    if @name =~ /sicker/i
      whinemsg = ["bot!!", "#{attacker_name} is a bot", "#{attacker_name} is camping",
                  "u cheat #{attacker_name}!"].rndpick
    end
    whinemsg
  end
  
end

