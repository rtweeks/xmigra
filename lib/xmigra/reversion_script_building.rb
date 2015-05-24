
require 'xmigra/plugin'

module XMigra
  module ReversionScriptBuilding
    # This module is intended to be included into XMigra::SchemaUpdater
    
    def reversions
      if @reversions.nil?
        @reversions = []
        migrations.reverse_each do |m|
          reversion = m.reversion
          break unless reversion
          @reversions << reversion
        end
      end
      
      return @reversions if @reversions
    end
    
    def reversion_script
      return nil if reversions.empty?
      
      usage_note = [
        "Run the reversion scripts below (separated by -- ======= -- dividers) in",
        "the order given to revert changes as far as desired.  Migrations should",
        "always be reverted in the order given in this file.  If any migration is",
        "not reverted and one further down this file is, XMigra will no longer be",
        "able to update the database schema.\n",
        "The query:",
        "",
        "    SELECT * FROM xmigra.last_applied_migrations ORDER BY \"RevertOrder\";",
        "",
        "lists the migrations applied by the last upgrade script run against this",
        "database.\n",
      ].collect {|l| '-- ' + l + "\n"}.join('')
      
      "".tap do |result|
        result << usage_note + "========================================\n"
        result << reversions.join("-- ================================== --\n")
        
        Plugin.active.amend_composed_sql(result) if Plugin.active
      end
    end
  end
end
