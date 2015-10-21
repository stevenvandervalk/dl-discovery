require 'time'
require 'json'
require 'nokogiri'
require_relative 'geonames'

# EnrichSolr forms a solr record from a vecnet XML record, passed in as a string.
# The formed solr record is in the format expected for the discovery solr core.
# The following broad tasks are done:
#
#  * Translate from the xml field names to the solr field names
#  * Add MeSH id labels and hierarchal faceting to subject entries
#  * Add NCBI id labels and hierarchal faceting to species entries
#  * Add geoname ids to location names
#  * Add geodata, coordinates, and bounding boxes for any place names
#  * Map any urls into a format expected by geoblacklight
#
# The hierarchal faceting is done only if a vecnet base url is passed in.
class EnrichSolr
  class AuthorityCache
    def initialize(base_url, authority_name)
      @url = base_url + "/authorities/" + authority_name
      @cache = {}
    end
    def lookup(term)
      info = @cache.fetch(term) do
        begin
          response = RestClient.get(@url, params: {q: term})
          info = JSON.parse(response)
          info.empty? ? nil : info
        rescue RestClient::Exception
          nil
        end
      end
      @cache[term] = info
      info
    end
    def get_formatted(term)
      info = self.lookup(term)
      return term, nil if info.nil?
      return "#{term} [#{info['id']}]", info['hierarchy']
    end
    def enrich_terms(terms)
      return nil, nil if terms.nil?
      new_term_list = []
      hierarchal_facets = []
      terms.each do |term|
        label, h_facet = self.get_formatted(term)
        new_term_list << label
        hierarchal_facets << h_facet
      end
      return new_term_list, hierarchal_facets.flatten.compact.uniq
    end
  end

  class ZeroAuthorityCache
    def lookup
      nil
    end
    def enrich_terms(terms)
      terms
    end
  end

  # cache_filename is the local JSON geonames cache file
  # harvest_url points to our source for authorities, and the source
  #   for extra info, such as full text items.
  # headers are additional headers we should pass for harvesting
  #   full text from the harvest_url (such as API keys)
  def initialize(cache_filename=nil, harvest_url=nil, headers={})
    # look up place names and info from geonames
    # But use the application authority to resolve place names into geonameids
    @geonames = Geonames.new(cache_filename)
    @harvest_url = harvest_url
    if @harvest_url
      @subjects = AuthorityCache.new(@harvest_url, 'subject-info')
      @species = AuthorityCache.new(@harvest_url, 'species-info')
      @locations = AuthorityCache.new(@harvest_url, 'location-info')
    else
      @subjects = @species = @locations = ZeroAuthorityCache.new
    end
    @headers = headers
  end

  def process_one(record_xml)
    xml = Nokogiri::XML(record_xml)

    noid = first_or_nil(xml, '//vn:identifier')
    return {} unless noid

    new_record = {
      uuid:             'vecnet:' + noid,
      layer_slug_s:     noid,
      layer_id_s:       noid,
      vn_content_version_s: first_or_nil(xml, '//vn:content_version'),

      dc_date_uploaded_dt: format_solr_date(first_or_nil(xml, '//dc:date_uploaded')),
      dc_date_modified_dt: format_solr_date(first_or_nil(xml, '//dc:date_modified')),

      read_access_group_sm: all_or_nil(xml, '//dc:access.read.group'),
      read_access_person_sm: all_or_nil(xml, '//dc:access.read.person'),
      edit_access_group_sm: all_or_nil(xml, '//dc:access.edit.group'),
      edit_access_person_sm: all_or_nil(xml, '//dc:access.edit.person'),

      dc_itentifier_sm: all_or_nil(xml,   '//dc:identifier'),
      dc_relation_sm:   all_or_nil(xml,   '//dc:related'),

      dc_title_s:       first_or_nil(xml, '//dc:title'),
      # dc_alternate is not exported by the xml

      dc_created_sm:    all_or_nil(xml,   '//dc:date_created'),
      dc_created_sort:  first_or_nil(xml, '//dc:date_created'),

      dc_type_s:        first_or_nil(xml, '//dc:type'),
      dc_format_s:      first_or_nil(xml, '//dc:format'),
      vn_filename_s:    first_or_nil(xml, '//vn:filename'),

      dc_description_s: first_or_nil(xml, '//dc:description'),

      dc_creator_sm:    all_or_nil(xml,   '//dc:creator'),
      dc_contributor_sm: all_or_nil(xml,  '//dc:contributor'),

      dc_subject_sm:    all_or_nil(xml,   '//dc:subject'),
      dwc_scientificname_sm: all_or_nil(xml, '//dwc:scientificName'),
      vn_keyword_sm:    all_or_nil(xml,   '//dc:relation'),
      dc_language_sm:   all_or_nil(xml,   '//dc:language'),

      # n.b. we use this field for intellectual rights. native geoblacklight
      # uses it for access rights
      dc_rights_s:      first_or_nil(xml, '//dc:rights'),

      dc_publisher_s:   first_or_nil(xml, '//dc:publisher'),
      dc_source_s:      first_or_nil(xml, '//dc:source'),
      dc_bibliographic_citation_s: first_or_nil(xml, '//dc:bibliographicCitation'),

      vn_related_items_sm: all_or_nil(xml, '//vn:related_files'),
      vn_child_records_sm: all_or_nil(xml, '//vn:child_records'),

      full_text:        first_or_nil(xml,  '//full_text'),

      dct_spatial_sm:   all_or_nil(xml,   '//dc:coverage'),
      dct_temporal_sm:  all_or_nil(xml,   '//dc:temporal'),

      # these are required ATM for geoblacklight...
      layer_geom_type_s: 'Point'
    }
    geoids = lookup_location_ids(new_record[:dct_spatial_sm])
    new_record.merge!(enrich_bounding_box(geoids))
    new_record[:point_list_s] = enrich_multipoint(geoids)
    labels, h_facet = enrich_location_names(geoids)
    new_record[:dct_spatial_sm] = labels
    new_record[:dct_spatial_h_facet] = h_facet

    labels, h_facet = @subjects.enrich_terms(new_record[:dc_subject_sm])
    new_record[:dc_subject_sm] = labels
    new_record[:dc_subject_h_facet] = h_facet

    labels, h_facet = @species.enrich_terms(new_record[:dwc_scientificname_sm])
    new_record[:dwc_scientificname_sm] = labels
    new_record[:dwc_scientificname_h_facet] = h_facet

    references = {
      "http://schema.org/downloadUrl" => all_or_nil(xml, "//vn:download"),
      "http://schema.org/url" => first_or_nil(xml, "//vn:purl"),
      "http://schema.org/thumbnailUrl" => first_or_nil(xml, "//vn:thumbnail")
    }
    references.delete_if { |k, v| v.nil? }
    new_record[:dct_references_s] = references.to_json

    # download children full_text if this is a citation
    if @harvest_url && new_record[:vn_child_records_sm]
      new_record[:full_text] = children_full_text(new_record[:vn_child_records_sm])
    end

    new_record.delete_if { |k, v| v.nil? }
    new_record
  end

  def save
    @geonames.save
  end

  private

  def lookup_location_ids(location_names)
    # first try to look up the location on the harvest place. Then we look
    # at geonames. Thus, the records in the discovery interface
    # conservatively extend the DL records.
    # return a list of tuples [place_name, geoid]. geoid may be nil.
    return [] if location_names.nil?
    location_names.map do |place|
      info = @locations.lookup(place)
      if info
        [place, info['id']]
      else
        short_place = place.split(",").first
        info = @geonames.lookup_name(short_place)
        if info
          [place, info['geonameId']]
        else
          [place, nil]
        end
      end
    end
  end

  # add all locations into a bounding box.
  # todo: include raw spatial coordinate data in the bounding box
  def enrich_bounding_box(geoids)
    return {} if geoids.empty?
    bbox = Geonames::Bbox.new
    geoids.each do |_, id|
      next if id.nil?
      info = @geonames.lookup_id(id)
      next if info.empty?
      if info['bbox']
        bbox.add_bbox(info['bbox'])
      else
        bbox.add_point(info)
      end
    end

    if bbox.valid?
      # nothing was added to this bounding box
      return {}
    end
    north = bbox.north
    south = bbox.south
    west = bbox.west
    east = bbox.east
    # solr does not like coordinates > 180 :(
    east -= 360 if east > 180
    # if Bbox is a point, enlarge it slightly so it is nicer.
    if north == south
      north += 0.1 if north <= 89.9
      south -= 0.1 if south >= -89.9
    end
    if east == west
      east += 0.1 if east <= 179.9
      west -= 0.1 if west >= -179.9
    end
    {
      "solr_bbox" => "#{west} #{south} #{east} #{north}",
      "solr_geom" => "ENVELOPE(#{west}, #{east}, #{north}, #{south})",
      "georss_box_s" => "#{south} #{west} #{north} #{east}",
      #"georss_polygon_s" => "#{north} #{west} #{north} #{east} #{south} #{east} #{south} #{west} #{north} #{west}"
    }
  end

  def enrich_multipoint(geoids)
    return nil if geoids.empty?
    point_list = geoids.map do |_, id|
      next if id.nil?
      info = @geonames.lookup_id(id)
      next if info.nil?
      info["lng"] + " " + info["lat"]
    end
    point_list.compact!
    return nil if point_list.length == 0
    "MULTIPOINT(" + point_list.join(", ") + ")"
  end

  def enrich_location_names(geoids)
    return nil if geoids.empty?
    hierarchal_facets = []
    better_place_names = geoids.map do |place, id|
      info = @geonames.lookup_id(id) unless id.nil?
      if id.nil? || info.nil? || info.empty?
        place
      else
        _, h_facet = @locations.get_formatted(place)
        hierarchal_facets << h_facet

        name = info['name']
        country = info['countryName']
        country = "(" + country + ")" if !country.nil?
        geoid = info['geonameId']
        fcode = info['fcode']
        "#{name} #{country} [#{geoid}/#{fcode}]"
      end
    end
    return better_place_names.uniq, hierarchal_facets.flatten.compact.uniq
  end

  def children_full_text(child_noids)
    child_noids.map do |child_record|
      begin
        response = RestClient.get(@harvest_url + "/files/#{child_record}.xml", @headers)
      rescue RestClient::Exception
        next
      end
      rxml = Nokogiri::XML(response)
      first_or_nil(rxml, '//full_text')
    end.join(' ')
  end

  def format_solr_date(date_string)
    return nil if date_string.nil? || date_string == ''
    d = Date.parse(date_string)
    d.strftime("%Y-%m-%dT%H:%M:%SZ")
  end

  def first_or_nil(xml, xpath)
    lst = xml.xpath(xpath).map(&:text)
    return nil if lst.empty?
    lst.first
  end

  def all_or_nil(xml, xpath)
    lst = xml.xpath(xpath).map(&:text)
    return nil if lst.empty?
    lst
  end
end
