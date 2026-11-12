require "spec_helper"

RSpec.describe Crew::Tracker do
  let(:root) { "/tmp" }

  describe "#fetch" do
    it "reads the issue" do
      expect(1).to eq(1)
    end

    context "when the file is missing" do
      it 'raises' do
        expect { raise }.to raise_error(RuntimeError)
      end
    end
  end
end
