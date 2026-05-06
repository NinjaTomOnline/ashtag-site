#!/usr/bin/env ruby

require "json"
require "cgi"

args = ARGV.dup
verbose = args.delete("--verbose")
json_output = args.delete("--json")

unless args.length == 2
  abort("Usage: ruby Scripts/verify_public_site_export.rb <exported_repo_root> <manifest_path> [--verbose] [--json]")
end

def read_file(path)
  File.read(path)
rescue Errno::ENOENT
  nil
end

def extract_match(content, pattern)
  return nil unless content

  match = content.match(pattern)
  match && match[1]
end

def extract_meta_content(content, attribute_name, attribute_value)
  return nil unless content

  content.scan(%r{<meta\b([^>]+)>}im).each do |(attributes)|
    parsed_attributes = attributes.scan(/([a-zA-Z:-]+)\s*=\s*"([^"]*)"/).to_h
    return parsed_attributes["content"] if parsed_attributes[attribute_name] == attribute_value
  end

  nil
end

def extract_nav(content)
  extract_match(content, %r{<nav class="site-nav" aria-label="Primary">(.*?)</nav>}im)
end

def extract_footer(content)
  extract_match(content, %r{<footer class="footer">(.*?)</footer>}im)
end

def extract_cta_hrefs(content)
  return [] unless content

  content.scan(%r{<a[^>]*class="([^"]+)"[^>]*href="([^"]+)"}im).each_with_object([]) do |(class_names, href), matches|
    classes = class_names.split(/\s+/)
    matches << href if (classes & %w[button button-secondary app-store-badge-link]).any?
  end
end

def extract_hrefs(content)
  return [] unless content

  content.scan(%r{href="([^"]+)"}im).flatten
end

def extract_anchor_pairs(content)
  return [] unless content

  content.scan(%r{<a\b[^>]*href="([^"]+)"[^>]*>(.*?)</a>}im).map do |href, inner_html|
    label = inner_html.gsub(%r{<[^>]+>}, " ")
    label = CGI.unescapeHTML(label).gsub(/\s+/, " ").strip
    { "href" => href, "label" => label }
  end
end

def appears_before?(content, needle, boundary)
  return false unless content

  needle_index = content.index(needle)
  boundary_index = content.index(boundary)
  return false unless needle_index && boundary_index

  needle_index < boundary_index
end

def parse_hex_color(value)
  match = value.to_s.strip.match(/\A#([0-9a-f]{6})\z/i)
  return nil unless match

  match[1].scan(/../).map { |component| component.to_i(16) / 255.0 }
end

def relative_luminance(rgb)
  channels = rgb.map do |channel|
    if channel <= 0.03928
      channel / 12.92
    else
      ((channel + 0.055) / 1.055)**2.4
    end
  end

  (0.2126 * channels[0]) + (0.7152 * channels[1]) + (0.0722 * channels[2])
end

def contrast_ratio(foreground, background)
  foreground_rgb = parse_hex_color(foreground)
  background_rgb = parse_hex_color(background)
  return nil unless foreground_rgb && background_rgb

  light, dark = [relative_luminance(foreground_rgb), relative_luminance(background_rgb)].sort.reverse
  (light + 0.05) / (dark + 0.05)
end

def extract_css_block(content, selector)
  return nil unless content

  match = content.match(/#{Regexp.escape(selector)}\s*\{([^}]+)\}/m)
  match && match[1]
end

def extract_css_declaration(content, selector, property)
  block = extract_css_block(content, selector)
  return nil unless block

  matches = block.scan(/^\s*#{Regexp.escape(property)}\s*:\s*([^;]+);/i).flatten
  matches.last&.strip
end

def px_value(value)
  match = value.to_s.strip.match(/\A(-?\d+(?:\.\d+)?)px\z/)
  match && match[1].to_f
end

def first_css_shorthand_value(value)
  value.to_s.strip.split(/\s+/).first
end

repo_root = File.expand_path(args.fetch(0))
manifest_path = File.expand_path(args.fetch(1))
manifest = JSON.parse(File.read(manifest_path))

failures = []

def add_failure(failures, section, path, message)
  failures << {
    "section" => section,
    "path" => path,
    "message" => message
  }
end

def print_results_as_json(repo_root, manifest_path, section_counts, failures)
  puts JSON.pretty_generate(
    {
      "ok" => failures.empty?,
      "repoRoot" => repo_root,
      "manifestPath" => manifest_path,
      "sections" => section_counts.transform_values { |count| { "checked" => count } },
      "failures" => failures
    }
  )
end

required_repo_files = {
  "CNAME" => /quitgentle\.com/i,
  "robots.txt" => %r{https://quitgentle\.com/sitemap\.xml}i,
  "sitemap.xml" => %r{https://quitgentle\.com/}i,
  ".github/workflows/github-pages.yml" => /Deploy GitHub Pages/i,
  ".github/workflows/verify-public-site.yml" => /Verify Public Site/i,
  "README.md" => /QuitGentle Public Site/i,
  "Scripts/verify_public_site_export.rb" => /socialMetadata/i,
  "docs/PUBLIC_SITE_EXPORT_ASSERTIONS.json" => /socialMetadata/i,
  ".github/ISSUE_TEMPLATE/support.yml" => /QuitGentle Support Request/i,
  ".github/ISSUE_TEMPLATE/config.yml" => /QuitGentle Support Page/i,
  "assets/badges/download-on-the-app-store.svg" => /Download_on_the_App_Store/i
}

maintainer_note = manifest["maintainerNote"]
add_failure(failures, "manifest", "maintainerNote", "missing maintainer note") unless maintainer_note.is_a?(String) && !maintainer_note.strip.empty?

required_repo_files.each do |relative_path, pattern|
  full_path = File.join(repo_root, relative_path)
  content = read_file(full_path)

  unless content
    add_failure(failures, "repoFiles", relative_path, "missing exported file")
    next
  end

  add_failure(failures, "repoFiles", relative_path, "missing expected content") unless content.match?(pattern)
end

pages = manifest.fetch("pages")
shared_nav = manifest.fetch("sharedNav")
required_ctas = manifest.fetch("requiredCtas")
required_footer_links = manifest.fetch("requiredFooterLinks")
required_copy_anchors = manifest.fetch("requiredCopyAnchors")
required_link_labels = manifest.fetch("requiredLinkLabels")
required_above_fold_assets = manifest.fetch("requiredAboveFoldAssets", {})
contrast_checks = manifest.fetch("contrastChecks", [])
layout_checks = manifest.fetch("layoutChecks", [])
social_metadata = manifest.fetch("socialMetadata", {})

section_counts = {
  "repoFiles" => required_repo_files.length,
  "pageMetadata" => pages.length,
  "socialMetadata" => social_metadata.sum { |_relative_path, expectations| expectations.fetch("property", {}).length + expectations.fetch("name", {}).length },
  "sharedNav" => shared_nav.length,
  "ctaLinks" => required_ctas.length,
  "footerLinks" => required_footer_links.length,
  "copyAnchors" => required_copy_anchors.length,
  "linkLabels" => required_link_labels.length,
  "aboveFoldAssets" => required_above_fold_assets.sum { |_relative_path, checks| checks.length },
  "contrastChecks" => contrast_checks.length,
  "layoutChecks" => layout_checks.sum { |check| check.fetch("rules", []).length }
}

pages.each do |relative_path, expectations|
  full_path = File.join(repo_root, relative_path)
  content = read_file(full_path)

  unless content
    add_failure(failures, "pageMetadata", relative_path, "missing exported file")
    next
  end

  title = extract_match(content, %r{<title>([^<]+)</title>}i)
  description = extract_match(content, %r{<meta\s+name="description"\s+content="([^"]+)"}im)

  add_failure(failures, "pageMetadata", relative_path, "title mismatch") unless title == expectations.fetch("title")
  add_failure(failures, "pageMetadata", relative_path, "description mismatch") unless description == expectations.fetch("description")
end

social_metadata.each do |relative_path, expectations|
  full_path = File.join(repo_root, relative_path)
  content = read_file(full_path)

  unless content
    add_failure(failures, "socialMetadata", relative_path, "missing exported file")
    next
  end

  expectations.fetch("property", {}).each do |property, expected_content|
    actual_content = extract_meta_content(content, "property", property)
    add_failure(failures, "socialMetadata", relative_path, "#{property} mismatch") unless actual_content == expected_content
  end

  expectations.fetch("name", {}).each do |name, expected_content|
    actual_content = extract_meta_content(content, "name", name)
    add_failure(failures, "socialMetadata", relative_path, "#{name} mismatch") unless actual_content == expected_content
  end
end

shared_nav.each do |relative_path, hrefs|
  full_path = File.join(repo_root, relative_path)
  content = read_file(full_path)
  next unless content

  nav = extract_nav(content)
  unless nav
    add_failure(failures, "sharedNav", relative_path, "missing shared nav")
    next
  end

  hrefs.each do |href|
    add_failure(failures, "sharedNav", relative_path, "missing nav link #{href}") unless nav.include?(%Q{href="#{href}"})
  end
end

required_ctas.each do |relative_path, hrefs|
  full_path = File.join(repo_root, relative_path)
  content = read_file(full_path)
  next unless content

  cta_hrefs = extract_cta_hrefs(content)
  hrefs.each do |href|
    add_failure(failures, "ctaLinks", relative_path, "missing CTA link #{href}") unless cta_hrefs.include?(href)
  end
end

required_footer_links.each do |relative_path, hrefs|
  full_path = File.join(repo_root, relative_path)
  content = read_file(full_path)
  next unless content

  footer = extract_footer(content)
  unless footer
    add_failure(failures, "footerLinks", relative_path, "missing footer")
    next
  end

  footer_hrefs = extract_hrefs(footer)
  hrefs.each do |href|
    add_failure(failures, "footerLinks", relative_path, "missing footer link #{href}") unless footer_hrefs.include?(href)
  end
end

required_copy_anchors.each do |relative_path, anchors|
  full_path = File.join(repo_root, relative_path)
  content = read_file(full_path)
  next unless content

  anchors.each do |anchor|
    add_failure(failures, "copyAnchors", relative_path, "missing copy anchor #{anchor.inspect}") unless content.include?(anchor)
  end
end

required_link_labels.each do |relative_path, expectations|
  full_path = File.join(repo_root, relative_path)
  content = read_file(full_path)
  next unless content

  anchors = extract_anchor_pairs(content)
  expectations.each do |expectation|
    href = expectation.fetch("href")
    label = expectation.fetch("label")
    matched = anchors.any? { |anchor| anchor["href"] == href && anchor["label"] == label }
    add_failure(failures, "linkLabels", relative_path, "missing link label #{label.inspect} for #{href}") unless matched
  end
end

required_above_fold_assets.each do |relative_path, expectations|
  full_path = File.join(repo_root, relative_path)
  content = read_file(full_path)
  next unless content

  expectations.each do |expectation|
    label = expectation.fetch("label")
    asset = expectation.fetch("asset")
    before = expectation.fetch("before")
    unless appears_before?(content, asset, before)
      add_failure(failures, "aboveFoldAssets", relative_path, "#{label} must reference #{asset.inspect} before #{before.inspect}")
    end
  end
end

contrast_checks.each do |check|
  relative_path = check.fetch("path")
  full_path = File.join(repo_root, relative_path)
  content = read_file(full_path)

  unless content
    add_failure(failures, "contrastChecks", relative_path, "missing exported file for #{check.fetch("name")}")
    next
  end

  check.fetch("requiredTokens", []).each do |token|
    unless content.include?(token)
      add_failure(failures, "contrastChecks", relative_path, "missing CSS token for #{check.fetch("name")}: #{token.inspect}")
    end
  end

  ratio = contrast_ratio(check.fetch("foreground"), check.fetch("background"))
  if ratio.nil?
    add_failure(failures, "contrastChecks", relative_path, "invalid contrast colors for #{check.fetch("name")}")
    next
  end

  minimum_ratio = check.fetch("minimumRatio").to_f
  if ratio < minimum_ratio
    add_failure(failures, "contrastChecks", relative_path, "#{check.fetch("name")} contrast #{ratio.round(2)} is below #{minimum_ratio}")
  end
end

layout_checks.each do |check|
  relative_path = check.fetch("path")
  full_path = File.join(repo_root, relative_path)
  content = read_file(full_path)

  unless content
    add_failure(failures, "layoutChecks", relative_path, "missing exported file for #{check.fetch("name")}")
    next
  end

  check.fetch("rules", []).each do |rule|
    selector = rule.fetch("selector")
    property = rule.fetch("property")
    value = extract_css_declaration(content, selector, property)
    label = "#{check.fetch("name")} #{selector} #{property}"

    unless value
      add_failure(failures, "layoutChecks", relative_path, "missing CSS declaration for #{label}")
      next
    end

    if rule.key?("equals") && value != rule.fetch("equals")
      add_failure(failures, "layoutChecks", relative_path, "#{label} expected #{rule.fetch("equals").inspect}, found #{value.inspect}")
    end

    if rule.key?("includes") && !value.include?(rule.fetch("includes"))
      add_failure(failures, "layoutChecks", relative_path, "#{label} must include #{rule.fetch("includes").inspect}, found #{value.inspect}")
    end

    rule.fetch("forbiddenValues", []).each do |forbidden_value|
      add_failure(failures, "layoutChecks", relative_path, "#{label} must not regress to #{forbidden_value.inspect}") if value == forbidden_value
    end

    if rule.key?("minimumPx")
      numeric_value = px_value(value)
      minimum = rule.fetch("minimumPx").to_f
      if numeric_value.nil? || numeric_value < minimum
        add_failure(failures, "layoutChecks", relative_path, "#{label} #{value.inspect} is below #{minimum}px")
      end
    end

    next unless rule.key?("topMinimumPx")

    top_value = first_css_shorthand_value(value)
    numeric_top = px_value(top_value)
    minimum_top = rule.fetch("topMinimumPx").to_f
    if numeric_top.nil? || numeric_top < minimum_top
      add_failure(failures, "layoutChecks", relative_path, "#{label} top value #{top_value.inspect} is below #{minimum_top}px")
    end
  end
end

if json_output
  print_results_as_json(repo_root, manifest_path, section_counts, failures)
  exit(failures.empty? ? 0 : 1)
end

unless failures.empty?
  lines = failures.map { |failure| "#{failure["path"]}: #{failure["message"]}" }
  abort("Exported public-site assertions failed:\n#{lines.join("\n")}")
end

if verbose
  puts "verify_public_site_export: ok"
  puts "  repo files: #{section_counts["repoFiles"]} checked"
  puts "  page metadata: #{section_counts["pageMetadata"]} pages checked"
  puts "  social metadata: #{section_counts["socialMetadata"]} tags checked"
  puts "  shared nav: #{section_counts["sharedNav"]} pages checked"
  puts "  cta links: #{section_counts["ctaLinks"]} pages checked"
  puts "  footer links: #{section_counts["footerLinks"]} pages checked"
  puts "  copy anchors: #{section_counts["copyAnchors"]} pages checked"
  puts "  link labels: #{section_counts["linkLabels"]} pages checked"
  puts "  above-fold assets: #{section_counts["aboveFoldAssets"]} checked"
  puts "  contrast checks: #{section_counts["contrastChecks"]} checked"
  puts "  layout checks: #{section_counts["layoutChecks"]} checked"
end
