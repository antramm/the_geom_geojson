module TheGeomGeoJSON
  module ActiveRecord
    class << self
      def included(model)
        model.class_eval do
          
          scope :with_geojson, -> { select('*', 'ST_AsGeoJSON( ST_Transform(geom, 3857) ) AS geom_geojson') }

          after_save do
            if @geom_geojson_dirty
              raise "can't update geom_geojson without an id" if id.nil?
              model.connection_pool.with_connection do |c|
                Rails.logger.debug("saving....'#{@geom_geojson_change}'")
                c.execute TheGeomGeoJSON::ActiveRecord.geom_sql(model, id, @geom_geojson_change)
              end
              @geom_geojson_dirty = false
              @geom_geojson_change = ''
              reload
            end
          end
        end
      end

      # @private
      def geom_sql(model, id, geom_geojson)
        sql = (begin
          cols = model.column_names
          has_geom = cols.include?('geom'), is_geom_empty = geom_geojson.blank?
          
          raise "Can't set geom_geojson on #{model.name} because it lacks geom columns" unless has_geom
          memo = []
          memo << "UPDATE #{model.quoted_table_name} SET "
          if has_geom
            if geom_geojson.present?
              # Transform GeoJson from Spherical Mercator (3857) to BNG (27700) on the way into DB
              memo << 'geom = ST_Transform( ST_SetSRID( ST_GeomFromGeoJSON(?), 3857), 27700 )'
            else
              memo << 'geom = NULL'
            end
          end
          memo << " WHERE #{model.quoted_primary_key} = ?"
          memo.join.freeze
        end)
        if has_geom
          if is_geom_empty
            Rails.logger.debug " empty.... #{sql}"
            model.send :sanitize_sql_array, [sql, id]
          else
            Rails.logger.debug " full.... #{sql}"
            model.send :sanitize_sql_array, [sql, geom_geojson, id]
          end
        end
      end
    end

    # memoizes update sql with bind placeholders
    @sql = {}

    def geom_geojson=(v)
      @geom_geojson_dirty = true
      @geom_geojson_change = TheGeomGeoJSON.sanitize_geojson v
    end
   
    def geom_geojson(simplify: nil)
      if @geom_geojson_dirty
        simplify ? raise("can't get simplified geom_geojson until you save") : @geom_geojson_change
      elsif !simplify and (preselected = read_attribute(:geom_geojson))
        preselected
      elsif geom
        self.class.connection_pool.with_connection do |c|
          sql = if simplify
            "SELECT ST_AsGeoJSON( ST_Transform( ST_Simplify( geom, #{c.quote(simplify)}::float ), 3857 ) ) FROM #{self.class.quoted_table_name} WHERE #{self.class.quoted_primary_key} = #{c.quote(id)} LIMIT 1"
          else
            "SELECT ST_AsGeoJSON( ST_Transform( geom, 3857) ) FROM #{self.class.quoted_table_name} WHERE #{self.class.quoted_primary_key} = #{c.quote(id)} LIMIT 1"
          end
          c.select_value sql
        end
      end
    end

    def geom
      if @geom_geojson_dirty
        raise TheGeomGeoJSON::Dirty, "geom can't be accessed on #{self.class.name} id #{id.inspect} until it has been saved"
      else
        read_attribute :geom
      end
    end

    def geom_webmercator
      if @geom_geojson_dirty
        raise TheGeomGeoJSON::Dirty, "geom_webmercator can't be accessed on #{self.class.name} id #{id.inspect} until it has been saved"
      else
        read_attribute :geom_webmercator
      end
    end
    
    def geometry(simplify: nil)
      @geom_json_object ||= geom_geojson.present? ? JSON.parse(geom_geojson) : nil
    end
    
    def geometry=(value)
      @geom_geojson_dirty = true
      @geom_geojson_change = value.present? ? TheGeomGeoJSON.sanitize_geojson(value.to_json) : nil
    end
  end
end
