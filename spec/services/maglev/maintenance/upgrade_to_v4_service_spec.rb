# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Maglev::Maintenance::UpgradeToV4Service, type: :service do
  let(:site) { create(:site) }
  let(:theme) { build(:theme, :with_simple_layout) }
  let!(:page) do
    build(:page) do |page|
      page['sections_translations'] = {
        en: [{ type: 'hero' }],
        fr: [{ type: 'hero', settings: { title: 'Bonjour' } }]
      }
      page.save!
    end
  end

  subject { described_class.call(site: site, theme: theme) }

  it 'creates a SectionsContentStore for both the site and the page' do
    expect_any_instance_of(described_class).to receive(:persist_layout_template).with(
      a_string_including('data-maglev-main-dropzone'),
      'default.html.erb'
    )
    expect { subject }.to change { Maglev::SectionsContentStore.count }.by(2)

    store = Maglev::SectionsContentStore.find_by(handle: 'main', page: page)
    expect(store.sections_translations['en'].first['type']).to eq('hero')
    expect(store.sections_translations['fr'].first['settings']['title']).to eq('Bonjour')

    expect(page.reload.layout_id).to eq('default')
  end

  context 'when the page was already published' do
    before do
      page.update!(
        published_at: 1.day.ago,
        published_payload: {
          'title_translations' => { 'en' => 'Home page' }
        }
      )
      allow_any_instance_of(described_class).to receive(:persist_layout_template)
    end

    it 'writes layout_id into the published payload' do
      subject

      expect(page.reload.published_payload['layout_id']).to eq('default')
      expect(page.published_payload['title_translations']).to eq('en' => 'Home page')
    end
  end

  context 'when content stores already exist' do
    let!(:site_store) do
      create(:sections_content_store, :site_scoped, :empty, sections: [{ type: 'navbar' }])
    end
    let!(:page_store) do
      create(:sections_content_store, page: page, handle: 'main', sections: [{ type: 'showcase' }])
    end
    let!(:published_site_wip) do
      create_legacy_published_store(
        container_type: 'Maglev::Site',
        container_id: site.id.to_s,
        sections_translations: {}
      )
    end
    let!(:published_page_wip) do
      create_legacy_published_store(
        container_type: 'Maglev::Page',
        container_id: page.id.to_s,
        sections_translations: { 'en' => [{ 'type' => 'jumbotron' }] }
      )
    end
    let!(:published_site_store) do
      create(:sections_content_store, :site_scoped, :published, :empty, sections: [{ type: 'navbar' }])
    end

    def create_legacy_published_store(**attributes)
      # Pre-v4 published stores shared handle "WIP" and were scoped by container.
      # The DB unique index allows multiple NULL maglev_page_id values; AR validation does not.
      Maglev::SectionsContentStore.new(
        { handle: 'WIP', published: true }.merge(attributes)
      ).tap { |store| store.save!(validate: false) }
    end

    before do
      allow_any_instance_of(described_class).to receive(:persist_layout_template)
    end

    it 'is idempotent and migrates leftover published WIP stores' do
      expect { subject }.not_to raise_error

      expect(Maglev::SectionsContentStore.unpublished.find_by(handle: '_site').id).to eq(site_store.id)
      expect(Maglev::SectionsContentStore.unpublished.find_by(handle: 'main', page: page).id).to eq(page_store.id)
      expect(page_store.reload.sections.first['type']).to eq('showcase')

      expect(Maglev::SectionsContentStore.exists?(published_site_wip.id)).to be(false)
      expect(Maglev::SectionsContentStore.published.find_by(handle: 'main', page: page).sections.first['type'])
        .to eq('jumbotron')
    end
  end
end
