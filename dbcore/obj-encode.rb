
require 'cgi'

module ObjEncodePrintable
  def obj_encode_to_printable(obj)
    CGI.escape(Marshal.dump(obj))
  end

  def obj_decode_from_printable(str)
    Marshal.load(CGI.unescape(str))
  end

  def obj_encode_with_label(label, obj)
    objenc = obj_encode_to_printable(obj)
    "OBJ/#{label}: #{objenc}"
  end

  def obj_decode_with_label(encdata)
    if encdata =~ /\AOBJ\/(\w+):\s+(\S+)\s*\z/
      label, encobj = $1, $2
      begin
        obj = obj_decode_from_printable(encobj)
      rescue StandardError => ex
        obj = ex
        label = "EXCEPTION!" + label
      end
      [label, obj]
    else
      nil
    end
  end
end

