class DmFlags

  DmFlagsMnemonics = {
    "health"           =>    -1,        # No Health.
    "powerups"         =>    -2,        # No Powerups.
    "weapons-stay"     =>     4,        # Weapons Stay.
    "falling-damage"   =>    -8,        # No Falling Damage.
    "instant-powerups" =>     16,       # Instant Powerups.
    "same-map"         =>     32,       # Same Map.
    "teams-by-skin"    =>     64,       # Teams by Skin.
    "teams-by-model"   =>     128,      # Teams by Model.
    "friendly-fire"    =>    -256,      # No Friendly Fire.
    "spawn-farthest"   =>     512,      # Spawn Farthest.
    "force-respawn"    =>     1024,     # Force Respawn.
    "armor"            =>    -2048,     # No Armor.
    "allow-exit"       =>     4096,     # Allow Exit.
    "infinite-ammo"    =>     8192,     # Infinite Ammo.
    "quad-drop"        =>     16384,    # Quad Drop.
    "fixed-fov"        =>     32768     # Fixed FOV.
  }
  
  DmFlagsShortAliasesToMnemonics = {
    "h"    => "health"          ,
    "pu"   => "powerups"        ,
    "ws"   => "weapons-stay"    ,
    "fd"   => "falling-damage"  ,
    "ip"   => "instant-powerups",
    "sm"   => "same-map"        ,
    "tbs"  => "teams-by-skin"   ,
    "tbm"  => "teams-by-model"  ,
    "ff"   => "friendly-fire"   ,
    "sf"   => "spawn-farthest"  ,
    "fr"   => "force-respawn"   ,
    "a"    => "armor"           ,
    "ae"   => "allow-exit"      ,
    "ax"   => "allow-exit"      ,
    "ia"   => "infinite-ammo"   ,
    "qd"   => "quad-drop"       ,
    "ffov" => "fixed-fov"       
  }
  
  DmFlagsMnemonicsToShortAliases = {}
  DmFlagsShortAliasesToMnemonics.each_pair do |als, mnem|
    (DmFlagsMnemonicsToShortAliases[mnem] ||= []) << als
  end

  class << self

    def alter(dmflags, args, logger)
      sets_clrs = args.scan(/[+-]\w+/).map {|flg| flg.downcase }
      sets_clrs = sub_aliases(sets_clrs)
      sets_clrs.each do |flg|
        dmflags = flag_setclr(dmflags, flg[1..-1], flg[0] == ?+, logger)
      end
      dmflags
    end

    def show(dmflags, logger)
      logger.log("dmflags: #{dmflags}", "")
      names = DmFlagsMnemonics.keys.sort
      names.each do |name|
        bit = DmFlagsMnemonics[name]
        invert = bit < 0
        bit = bit.abs
        setclr = ((dmflags & bit) != 0) ^ invert
        aliases = DmFlagsMnemonicsToShortAliases[name].join(",")
        logger.log("  #{setclr ? '+' : '-'}#{name} (#{aliases})", "")
      end
    end

    private

    def flag_setclr(dmflags, flg, setclr, logger)
      bit = DmFlagsMnemonics[flg]
      if bit
      # logger.log("  * #{setclr ? ' setting' : 'clearing'}: #{flg}", "")
        if bit < 0
          bit = bit.abs
          setclr = !setclr
        end
        setclr ? (dmflags |= bit) : (dmflags &= ~bit)
      else
        logger.log(ANSI.dbwarn("  UNRECOGNIZED DMFLAG: #{flg}"), "")
      end
      dmflags
    end

    def sub_aliases(flags)
      flags.map do |flg|
        mnem = DmFlagsShortAliasesToMnemonics[flg[1..-1]]
        flg[1..-1] = mnem if mnem
        flg
      end
    end
    
  end

end

