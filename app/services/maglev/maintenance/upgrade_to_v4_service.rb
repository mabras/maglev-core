# frozen_string_literal: true

module Maglev
  module Maintenance
    class UpgradeToV4Service
      include Injectable

      argument :site
      argument :theme

      def call
        ActiveRecord::Base.transaction do
          unsafe_call
        end
      end

      private

      def unsafe_call
        migrate_site_scoped_sections
        migrate_pages
        upgrade_layout_template
      end

      def migrate_site_scoped_sections
        upsert_unpublished_store(
          handle: ::Maglev::SectionsContentStore::SITE_HANDLE,
          page: nil,
          sections_translations: site['sections_translations']
        )

        # don't forget the published site scoped sections
        migrate_published_stores(
          Maglev::SectionsContentStore.published.where(container_type: 'Maglev::Site'),
          handle: ::Maglev::SectionsContentStore::SITE_HANDLE,
          page: nil
        )
      end

      def migrate_pages
        pages.find_each do |page|
          upgrade_page(page)
        end
      end

      def upgrade_page(page)
        create_sections_content_store(page)

        page.layout_id = default_layout.id
        sync_published_layout_id!(page)
        page.save!
      end

      def sync_published_layout_id!(page)
        return unless page.published?

        # Live rendering applies published_payload, which would wipe layout_id if absent.
        page.published_payload ||= {}
        page.published_payload['layout_id'] = page.layout_id
      end

      def create_sections_content_store(page)
        upsert_unpublished_store(
          handle: default_layout_group.handle,
          page: page,
          sections_translations: page['sections_translations']
        )

        # don't forget the published page sections
        migrate_published_stores(
          Maglev::SectionsContentStore.published.where(container_type: 'Maglev::Page', container_id: page.id),
          handle: default_layout_group.handle,
          page: page
        )
      end

      def upsert_unpublished_store(handle:, page:, sections_translations:)
        store = Maglev::SectionsContentStore.find_or_initialize_by(
          handle: handle,
          maglev_page_id: page&.id,
          published: false
        )

        if store.new_record? || store_sections_blank?(store)
          store.sections_translations = sections_translations
        end

        store.page = page if page
        store.save!
      end

      def migrate_published_stores(scope, handle:, page:)
        scope.find_each do |store|
          existing = Maglev::SectionsContentStore.published.find_by(
            handle: handle,
            maglev_page_id: page&.id
          )

          if existing && existing.id != store.id
            merge_published_store!(existing, store, page)
          else
            attrs = { handle: handle }
            attrs[:page] = page if page
            store.update!(attrs)
          end
        end
      end

      def merge_published_store!(existing, legacy_store, page)
        attrs = {}
        attrs[:page] = page if page && existing.maglev_page_id.blank?
        if store_sections_blank?(existing) && !store_sections_blank?(legacy_store)
          attrs[:sections_translations] = legacy_store.sections_translations
        end
        existing.update!(attrs) if attrs.any?
        legacy_store.destroy!
      end

      def store_sections_blank?(store)
        translations = store.sections_translations
        translations.blank? || translations.values.all?(&:blank?)
      end

      def upgrade_layout_template
        template = load_old_layout_template
                   .gsub('data-maglev-dropzone',
                         "data-maglev-#{default_layout_group.id}-dropzone")
                   .gsub('render_maglev_sections', "render_maglev_group :#{default_layout_group.id}")

        persist_layout_template(template, "#{default_layout.id}.html.erb")
      end

      def pages
        Maglev::Page
      end

      def default_layout
        theme.layouts.first
      end

      def default_layout_group
        default_layout.page_scoped_stores.first || default_layout.groups.first
      end

      def load_old_layout_template
        File.read(Rails.root.join('app/views/theme/layout.html.erb').to_s)
      end

      def persist_layout_template(content, filename)
        File.write(Rails.root.join("app/views/theme/layouts/#{filename}").to_s, content)
      end
    end
  end
end
