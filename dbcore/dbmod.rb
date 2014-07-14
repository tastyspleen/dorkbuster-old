
module DBMod

  class << self
    def reload_modules(dir, names, logger)
      names = [names] unless names.kind_of? Array
      names.each {|name| load_module("#{dir}/#{name}.rb", logger) }
      perform_live_reinit(logger)
    end
  
    def load_module(filename, logger)
      ok = false
      old_v = $VERBOSE
      begin
        $VERBOSE = false
        errmsg = ""
        begin
          ok = load filename
          errmsg = "load returned false" unless ok
        rescue Exception => ex
          errmsg = ex.to_s.split(/\n/)[0]
          puts "load_module: caught exception: #{errmsg} loading #{filename}"
        end
        color = ok ? ANSI::DBWarn : ANSI::DBErr
        msg = "load #{filename} " + (ok ? "[OK]" : "[FAIL] #{errmsg}")
        logger.log(ANSI.colorize(msg, color))
      ensure
        $VERBOSE = old_v
      end
      ok
    end
  
    def perform_live_reinit(logger)
      objs, inits, errors = 0, 0, 0
      ObjectSpace.each_object do |obj|
        begin
          objs += 1
          if obj.respond_to? :live_reinit
            inits += 1
            obj.live_reinit
          end
        rescue Exception => ex
          errors += 1
          errmsg = ex.to_s.split(/\n/)[0]
          puts "perform_live_reinit: caught exception: #{errmsg} on obj #{obj.inspect}"
        end
      end
      color = (errors == 0) ? ANSI::DBWarn : ANSI::DBErr
      msg = "LIVE REINIT: #{objs} live objects, #{inits} inits performed, "
      msg << ((errors == 0) ? "no errors." : "#{errors} inits failed.")
      logger.log(ANSI.colorize(msg, color))
    end
  end
  
end

