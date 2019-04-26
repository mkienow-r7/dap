require 'maxmind/db'

module Dap
module Filter

require 'dap/utils/misc'

module GeoIP2Library
  GEOIP_DIRS = [
    File.expand_path( File.join( File.dirname(__FILE__), "..", "..", "..", "data")),
    "/var/lib/geoip",
    "/var/lib/geoip2"
  ]
  GEOIP_CITY = %W{ GeoLite2-City.mmdb }
  GEOIP_ASN = %W{ GeoLite2-ASN.mmdb }
  GEOIP_ISP = %W{ GeoIP2-ISP.mmdb }

  @@geo_city = nil
  @@geo_asn = nil
  @@geo_isp = nil

  GEOIP2_CITY_DATABASE_PATH = ENV["GEOIP2_CITY_DATABASE_PATH"]
  GEOIP2_ASN_DATABASE_PATH = ENV["GEOIP2_ASN_DATABASE_PATH"]
  GEOIP2_ISP_DATABASE_PATH = ENV["GEOIP2_ISP_DATABASE_PATH"]

  if GEOIP2_CITY_DATABASE_PATH
    if ::File.exist?(GEOIP2_CITY_DATABASE_PATH)
      @@geo_city = MaxMind::DB.new(GEOIP2_CITY_DATABASE_PATH, mode: MaxMind::DB::MODE_MEMORY)
    end
  else
    GEOIP_DIRS.each do |d|
      GEOIP_CITY.each do |f|
        path = File.join(d, f)
        if ::File.exist?(path)
          @@geo_city = MaxMind::DB.new(path, mode: MaxMind::DB::MODE_MEMORY)
          break
        end
      end
    end
  end

  if GEOIP2_ASN_DATABASE_PATH
    if ::File.exist?(GEOIP2_ASN_DATABASE_PATH)
      @@geo_asn = MaxMind::DB.new(GEOIP2_ASN_DATABASE_PATH, mode: MaxMind::DB::MODE_MEMORY)
    end
  else
    GEOIP_DIRS.each do |d|
      GEOIP_ASN.each do |f|
        path = File.join(d, f)
        if ::File.exist?(path)
          @@geo_asn = MaxMind::DB.new(path, mode: MaxMind::DB::MODE_MEMORY)
          break
        end
      end
    end
  end

  if GEOIP2_ISP_DATABASE_PATH
    if ::File.exist?(GEOIP2_ISP_DATABASE_PATH)
      @@geo_isp = MaxMind::DB.new(GEOIP2_ISP_DATABASE_PATH, mode: MaxMind::DB::MODE_MEMORY)
    end
  else
    GEOIP_DIRS.each do |d|
      GEOIP_ISP.each do |f|
        path = File.join(d, f)
        if ::File.exist?(path)
          @@geo_isp = MaxMind::DB.new(path, mode: MaxMind::DB::MODE_MEMORY)
          break
        end
      end
    end
  end
end


#
# Add GeoIP2 tags using the MaxMind GeoIP2::City
#
class FilterGeoIP2City
  include BaseDecoder
  include GeoIP2Library

  GEOIP2_LANGUAGE = ENV["GEOIP2_LANGUAGE"] || "en"
  LOCALE_SPECIFIC_NAMES = %w(city.names continent.names country.names registered_country.names represented_country.names)
  DESIRED_GEOIP2_KEYS = %w(
    city.geoname_id
    continent.code continent.geoname_id
    country.geoname_id country.iso_code country.is_in_european_union
    location.accuracy_radius location.latitude location.longitude location.metro_code location.time_zone
    postal.code
    registered_country.geoname_id registered_country.iso_code registered_country.is_in_european_union
    represented_country.geoname_id represented_country.iso_code represented_country.is_in_european_union represented_country.type
    traits.is_anonymous_proxy traits.is_satellite_provider
  )

  attr_reader :locale_specific_names
  def initialize(args={})
    @locale_specific_names = LOCALE_SPECIFIC_NAMES.map { |lsn| "#{lsn}.#{GEOIP2_LANGUAGE}" }
    super
  end

  def decode(ip)
    unless @@geo_city
      raise "No MaxMind GeoIP2::City data found"
    end
    return unless (geo_hash = @@geo_city.get(ip))
    ret = defaults

    if geo_hash.include?("subdivisions")
      # handle countries that are divided into various subdivisions.  generally 1, sometimes 2
      subdivisions = geo_hash["subdivisions"]
      geo_hash.delete("subdivisions")
      ret["geoip2.city.subdivisions.length"] = subdivisions.size.to_s
      subdivisions.each_index do |i|
        subdivision = subdivisions[i]
        subdivision.each_pair do |k,v|
          if %w(geoname_id iso_code).include?(k)
            ret["geoip2.city.subdivisions.#{i}.#{k}"] = v.to_s
          elsif k == "names"
            if v.include?(GEOIP2_LANGUAGE)
              ret["geoip2.city.subdivisions.#{i}.name"] = subdivision["names"][GEOIP2_LANGUAGE]
            end
          end
        end
      end
    end

    Dap::Utils::Misc.flatten_hash(geo_hash).each_pair do |k,v|
      if DESIRED_GEOIP2_KEYS.include?(k)
        # these keys we can just copy directly over
        ret["geoip2.city.#{k}"] = v
      elsif @locale_specific_names.include?(k)
        # these keys we need to pick the locale-specific name and set the key accordingly
        lsn_renamed = k.gsub(/\.names.#{GEOIP2_LANGUAGE}/, ".name")
        ret["geoip2.city.#{lsn_renamed}"] = v
      end
    end
    ret
  end

  def defaults()
    ret = {}
    default_int_suffixes = %w(geoname_id metro_code)
    default_bool_suffixes = %w(is_in_european_union is_anonymous_proxy is_satellite_provider)
    DESIRED_GEOIP2_KEYS.each do |k|
      suffix = k.split(/\./)[-1]
      if default_int_suffixes.include?(suffix)
        ret["geoip2.city.#{k}"] = "0"
      elsif default_bool_suffixes.include?(suffix)
        ret["geoip2.city.#{k}"] = "false"
      else
        ret["geoip2.city.#{k}"] = ""
      end
    end
    ret
  end
end

#
# Add GeoIP2 ASN and Org tags using the MaxMind GeoIP2::ASN database
#
class FilterGeoIP2Asn
  include BaseDecoder
  include GeoIP2Library

  def decode(ip)
    unless @@geo_asn
      raise "No MaxMind GeoIP2::ASN data found"
    end
    geo_hash = @@geo_asn.get(ip)
    return unless geo_hash

    ret = {}

    if geo_hash.include?("autonomous_system_number")
      ret["geoip2.asn.asn"] = "AS#{geo_hash["autonomous_system_number"]}"
    else
      ret["geoip2.asn.asn"] = ""
    end

    if geo_hash.include?("autonomous_system_organization")
      ret["geoip2.asn.asn_org"] = "#{geo_hash["autonomous_system_organization"]}"
    else
      ret["geoip2.asn.asn_org"] = ""
    end

    ret
  end
end

#
# Add GeoIP2 ISP tags using the MaxMind GeoIP2::ISP database
#
class FilterGeoIP2Isp
  include BaseDecoder
  include GeoIP2Library
  def decode(ip)
    unless @@geo_isp
      raise "No MaxMind GeoIP2::ISP data found"
    end
    geo_hash = @@geo_isp.get(ip)
    return unless geo_hash

    ret = {}

    if geo_hash.include?("autonomous_system_number")
      ret["geoip2.isp.asn"] = "AS#{geo_hash["autonomous_system_number"]}"
    else
      ret["geoip2.isp.asn"] = ""
    end

    if geo_hash.include?("autonomous_system_organization")
      ret["geoip2.isp.asn_org"] = geo_hash["autonomous_system_organization"]
    else
      ret["geoip2.isp.asn_org"] = ""
    end
    if geo_hash.include?("autonomous_system_organization")
      ret["geoip2.isp.asn_org"] = geo_hash["autonomous_system_organization"]
    else
      ret["geoip2.isp.asn_org"] = ""
    end

    if geo_hash.include?("isp")
      ret["geoip2.isp.isp"] = geo_hash["isp"]
    else
      ret["geoip2.isp.isp"] = ""
    end

    if geo_hash.include?("organization")
      ret["geoip2.isp.org"] = geo_hash["organization"]
    else
      ret["geoip2.isp.org"] = ""
    end

    ret
  end
end

#
# Convert GeoIP2 data as closely as possible to the legacy GeoIP data as generated by geo_ip, geo_ip_asn and geo_ip_org
#
class FilterGeoIP2LegacyCompat
  include Base

  attr_accessor :base_field

  def initialize(args)
    super
    fail "Expected 1 arguments to '#{self.name}' but got #{args.size}" unless args.size == 1
    self.base_field = args.first
  end

  def process(doc)
    # all of these values we just take directly and rename
    remap = {
      # geoip2 name -> geoip name
      "city.country.iso_code": "country_code",
      "city.country.name": "country.name",
      "city.postal.code": "postal_code",
      "city.location.latitude": "latitude",
      "city.location.longitude": "longitude",
      "city.city.name": "city",
      "city.subdivisions.0.iso_code": "region",
      "city.subdivisions.0.name": "region_name",
    }

    remap.each_pair do |geoip2,geoip|
      geoip2_key = "#{self.base_field}.geoip2.#{geoip2}"
      if doc.include?(geoip2_key)
        doc["#{self.base_field}.#{geoip}"] = doc[geoip2_key]
      end
    end

    # these values all require special handling

    # https://dev.maxmind.com/geoip/geoip2/whats-new-in-geoip2/#Custom_Country_Codes
    # which basically says if traits.is_anonymous_proxy is true, previously the
    # country_code would have had a special value of A1.  Similarly, if
    # traits.is_satellite_provider is true, previously the country_code would
    # have a special value of A2.
    anon_key = "#{self.base_field}.geoip2.city.traits.is_anonymous_proxy"
    if doc.include?(anon_key)
      anon_value = doc[anon_key]
      if anon_value == "true"
        doc["#{self.base_field}.country_code"] = "A1"
      end
    end

    satellite_key = "#{self.base_field}.geoip2.city.traits.is_satellite_provider"
    if doc.include?(satellite_key)
      satellite_value = doc[satellite_key]
      if satellite_value == "true"
        doc["#{self.base_field}.country_code"] = "A1"
      end
    end

    # only set dma_code if location.metro_code was set and not empty or 0
    metro_key = "#{self.base_field}.geoip2.city.location.metro_code}"
    if doc.include?(metro_key)
      metro_value = doc[metro_key]
      if !metro_value.empty? && metro_value != "0"
        doc["#{self.base_field}.dma_code"] = metro_value
      end
    end

    [ doc ]
  end
end

end
end
