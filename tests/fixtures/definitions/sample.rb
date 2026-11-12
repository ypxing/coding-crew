require "json"

module Crew
  class Tracker
    def initialize(root)
      @root = root
    end

    def self.from_env
      new(ENV.fetch("ROOT", "."))
    end

    def fetch(ref)
      File.read(File.join(@root, ref))
    end
  end
end
