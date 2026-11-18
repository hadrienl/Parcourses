#!/usr/bin/env ruby
# frozen_string_literal: true

# Fiche App Store (#145) : vérifie, sans réseau ni gem, les textes de ios/fastlane/metadata avant un envoi par
# `fastlane metadata`. Limites d'App Store Connect, catégories, URL, classification 4+, pas d'emoji.
# Usage : ruby ios/scripts/check-store-metadata.rb (lancé aussi par `fastlane check` et par la CI).
require "json"

FASTLANE = File.expand_path("../fastlane", __dir__)
METADATA = File.join(FASTLANE, "metadata")
LOCALE = "fr-FR"

# Limites d'App Store Connect, en caractères.
LIMITS = {
  "name.txt" => 30,
  "subtitle.txt" => 30,
  "keywords.txt" => 100,
  "promotional_text.txt" => 170,
  "description.txt" => 4000
}.freeze
URLS = %w[support_url.txt marketing_url.txt privacy_url.txt].freeze
PRIVACY_URL = "https://parcourses.hadrien.eu/confidentialite/"
# Identifiants de catégorie de l'API App Store Connect (appCategories).
CATEGORIES = %w[
  BOOKS BUSINESS DEVELOPER_TOOLS EDUCATION ENTERTAINMENT FINANCE FOOD_AND_DRINK GAMES GRAPHICS_AND_DESIGN
  HEALTH_AND_FITNESS LIFESTYLE MAGAZINES_AND_NEWSPAPERS MEDICAL MUSIC NAVIGATION NEWS PHOTO_AND_VIDEO PRODUCTIVITY
  REFERENCE SHOPPING SOCIAL_NETWORKING SPORTS STICKERS TRAVEL UTILITIES WEATHER
].freeze
# Pictogrammes et emoji : interdits dans la fiche.
EMOJI = /[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{FE0F}]/

errors = []
read = lambda do |relative|
  path = File.join(METADATA, relative)
  unless File.file?(path)
    errors << "#{relative} manquant"
    next ""
  end
  text = File.read(path, encoding: "UTF-8")
  errors << "#{relative} : encodage UTF-8 invalide" unless text.valid_encoding?
  # deliver retire le saut de ligne final : il ne compte pas.
  text.chomp
end

# Marques et enseignes : interdites dans les textes (règle 2.3.7 de l'App Review), mots-clés compris.
BRANDS = %w[
  caddie nesquik nutella leclerc carrefour intermarché auchan lidl aldi monoprix franprix casino super-u système-u
  bring anylist listonic
].freeze

LIMITS.each do |file, limit|
  text = read.call(File.join(LOCALE, file))
  errors << "#{LOCALE}/#{file} vide" if text.strip.empty?
  errors << "#{LOCALE}/#{file} : #{text.length} caractères, #{limit} au plus" if text.length > limit
  errors << "#{LOCALE}/#{file} : emoji ou pictogramme" if text.match?(EMOJI)
  errors << "#{LOCALE}/#{file} : espaces en début ou fin" if text != text.strip
  brands = text.downcase.scan(/[[:alpha:]-]+/) & BRANDS
  errors << "#{LOCALE}/#{file} : marque citée : #{brands.join(', ')}" unless brands.empty?
end
%w[name.txt subtitle.txt keywords.txt promotional_text.txt].each do |file|
  errors << "#{LOCALE}/#{file} : une seule ligne attendue" if read.call(File.join(LOCALE, file)).include?("\n")
end

# Mots-clés : séparés par des virgules, sans espace autour ni doublon, et sans reprendre le nom ni le sous-titre
# (déjà indexés par Apple : un mot répété gaspille la limite).
keywords = read.call(File.join(LOCALE, "keywords.txt")).split(",", -1)
errors << "keywords.txt : mot-clé vide" if keywords.any? { |k| k.strip.empty? }
errors << "keywords.txt : espace autour d'une virgule" if keywords.any? { |k| k != k.strip }
errors << "keywords.txt : doublon" if keywords.map(&:downcase).uniq.length != keywords.length
title_words = %w[name.txt subtitle.txt].flat_map do |file|
  read.call(File.join(LOCALE, file)).downcase.scan(/[[:alpha:]-]+/)
end
repeated = keywords.map { |k| k.strip.downcase } & title_words
errors << "keywords.txt : déjà dans le nom ou le sous-titre : #{repeated.join(', ')}" unless repeated.empty?

URLS.each do |file|
  url = read.call(File.join(LOCALE, file))
  errors << "#{LOCALE}/#{file} : URL https attendue, trouvé « #{url} »" unless url.match?(%r{\Ahttps://[^\s]+\z})
end
privacy = read.call(File.join(LOCALE, "privacy_url.txt"))
errors << "privacy_url.txt : #{PRIVACY_URL} attendue" unless privacy == PRIVACY_URL

%w[primary_category.txt secondary_category.txt].each do |file|
  category = read.call(file)
  errors << "#{file} : catégorie inconnue « #{category} »" unless CATEGORIES.include?(category)
end
if read.call("primary_category.txt") == read.call("secondary_category.txt")
  errors << "catégories principale et secondaire identiques"
end
errors << "copyright.txt : « <année> <titulaire> » attendu" unless read.call("copyright.txt").match?(/\A20\d\d \S/)

# Classification 4+ : toutes les réponses à « NONE » ou false, sans tranche Kids ni surclassement. Seule exception, le
# contenu généré par les utilisateurs : les libellés tapés alimentent le catalogue commun, proposé à tous en
# autocomplétion (#47, #138). Cette réponse ne change pas la classe d'âge.
UGC_KEYS = %w[userGeneratedContent].freeze
rating_path = File.join(FASTLANE, "age_rating.json")
begin
  rating = JSON.parse(File.read(rating_path))
  rating.each do |key, value|
    next if value == "NONE" || value == false || (key == "kidsAgeBand" && value.nil?)
    next if UGC_KEYS.include?(key) && value == true

    errors << "age_rating.json : #{key} = #{value.inspect}, l'app est classée 4+"
  end
rescue Errno::ENOENT, JSON::ParserError => e
  errors << "age_rating.json illisible : #{e.message}"
end

if errors.empty?
  description = read.call(File.join(LOCALE, "description.txt"))
  puts "Fiche App Store conforme (description : #{description.length} caractères sur 4000)."
else
  warn errors.map { |e| "✗ #{e}" }
  exit 1
end
