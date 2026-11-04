#include "icon_family.hpp"
#include "../fox-common/json.hpp"
#include <fstream>
#include <sstream>
#include <set>

namespace fs = std::filesystem;
using json = nlohmann::json;
namespace fox_render {
namespace {
std::string read(const fs::path& p) {
    std::ifstream in(p);return {std::istreambuf_iterator<char>(in), {}};
}
bool write(const fs::path& p,const std::string& text) {
    return atomic_write(p,text,fs::perms::owner_read|fs::perms::owner_write|fs::perms::group_read|fs::perms::others_read);
}
bool block(const fs::path& p,const std::string& id,const std::string& body) {
    auto text=read(p);
    const auto first=text.find("foxml:"+id+"-begin"),last=text.find("foxml:"+id+"-end");
    if(first==std::string::npos||last==std::string::npos||last<first)return false;
    const auto start=text.find('\n',first),end=text.rfind('\n',last)+1;
    text.replace(start+1,end-start-1,body);
    return write(p,text);
}
std::string xml(const std::string& text) {
    std::string out;
    for(char c:text) {switch(c){case '&':out+="&amp;";break;case '<':out+="&lt;";break;case '>':out+="&gt;";break;case '"':out+="&quot;";break;default:out+=c;}}
    return out;
}
std::string json_string(const json& value) {return value.dump(-1,' ',false,json::error_handler_t::replace);}
bool component(const std::string& text) {
    return !text.empty()&&text.find("..") == std::string::npos&&text.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.+")==std::string::npos;
}
}

bool finish_icon_family(const fs::path& templates,const fs::path& output,
                        const std::unordered_map<std::string,std::string>& palette) {
    fs::path source=templates/"icons/icon-family.json";
    bool full=fs::exists(source),icons=templates.filename()=="icons";
    if(!full)source=templates.parent_path()/"icons/icon-family.json";
    if(!fs::exists(source))return true;
    auto family=json::parse(apply_substitutions(read(source),palette),nullptr,false);
    if(!family.is_object()||!family.contains("families")||!family["families"].is_array())return false;
    if(family.value("enabled",std::string())!="fox-little-details-on")return true;
    const auto eza=full?output/"eza/theme.yml":templates.filename()=="eza"?output/"theme.yml":fs::path();
    const auto yazi=full?output/"yazi/theme.toml":templates.filename()=="yazi"?output/"theme.toml":fs::path();
    const auto nvim=full?output/"nvim/init.lua":templates.filename()=="nvim"?output/"init.lua":fs::path();
    const auto init=full?output/"yazi/init.lua":templates.filename()=="yazi"?output/"init.lua":fs::path();
    const auto vectors=full?output/"icons/foxml-paper":icons?output/"foxml-paper":fs::path();
    json extension_map=json::object(),names=json::object(),directories=json::object();
    std::string icon_rules="[icon]\nglobs = []\ndirs = []\nfiles = [\n",ext_rules;
    std::string aliases="[FoxML Aliases]\n";
    const auto accent=family["accent"],ink=family["ink"],muted=family["muted"];
    icon_rules="[filetype]\nrules = [\n    { url = \"*\", is = \"orphan\", fg = "+json_string(family["error"])+" },\n    { url = \"*/\", fg = "+json_string(ink)+", bold = true },\n    { url = \"*\", fg = "+json_string(ink)+" },\n]\n\n"+icon_rules;
    for(const auto& entry:family["families"]) {
        const auto asset=entry.value("asset",std::string());
        if(!component(asset)||!entry.contains("glyph")||!entry["glyph"].is_string()||!entry.contains("extensions")||!entry["extensions"].is_array()||!entry.contains("mimes")||!entry["mimes"].is_array())return false;
        const auto color=entry.value("muted",false)?muted:accent;
        const json style={{"filename",{{"foreground",entry.value("muted",false)?muted:ink}}},{"icon",{{"glyph",entry["glyph"]},{"style",{{"foreground",color}}}}}};
        for(const auto& extension:entry["extensions"]) {
            if(!extension.is_string()||!component(extension))return false;
            extension_map[extension.get<std::string>()]=style;
            ext_rules+="    { name = "+json_string(extension)+", text = "+json_string(entry["glyph"].get<std::string>()+"  ")+", fg = "+json_string(color)+" },\n";
        }
        if(entry.contains("names"))for(const auto& name:entry["names"]) {
            if(!name.is_string())return false;
            names[name.get<std::string>()]=style;
            icon_rules+="    { name = "+json_string(name)+", text = "+json_string(entry["glyph"].get<std::string>()+"  ")+", fg = "+json_string(color)+" },\n";
        }
        std::set<std::string> mime_icons;
        for(const auto& mime:entry["mimes"]) {
            if(!mime.is_string())return false;
            auto name=mime.get<std::string>();
            for(auto& c:name)if(c=='/')c='-';
            if(!component(name))return false;
            if(name!=asset)mime_icons.insert(name);
        }
        aliases+=asset+"=";
        for(const auto& name:mime_icons)aliases+=name+",";
        if(!mime_icons.empty())aliases.pop_back();
        aliases+='\n';
        if(!vectors.empty()&&!entry.value("existing_vector",false)) {
            auto svg=read(vectors/"scalable/mimetypes/text-plain.svg");
            const auto from=svg.find("  <path d=\"M18 21h13"),to=svg.find("/>",from);
            if(from==std::string::npos||to==std::string::npos)return false;
            const auto badge=entry.value("badge",entry["glyph"].get<std::string>());
            std::string tag="  <text x=\"24\" y=\"30\" text-anchor=\"middle\" font-family=\""+xml(family["font"])+"\" font-size=\""+(entry.contains("badge")?"9":"15")+"\" fill=\""+xml(entry.value("muted",false)?muted:ink)+"\">"+xml(badge)+"</text>";
            svg.replace(from,to+2-from,tag);
            if(!write(vectors/"scalable/mimetypes"/(asset+".svg"),svg))return false;
        }
    }
    if(family.contains("folders"))for(const auto& folder:family["folders"]) {
        const auto asset=folder.value("asset",std::string());
        if(!component(asset)||!folder.contains("glyph")||!folder["glyph"].is_string()
            ||!folder.contains("names")||!folder["names"].is_array())return false;
        for(const auto& name:folder["names"]) {
            if(!name.is_string()||!component(name))return false;
            directories[name.get<std::string>()]={{"glyph",folder["glyph"]},{"style",{{"foreground",ink}}}};
        }
        aliases+=asset+"=";
        for(const auto& alias:folder["aliases"]) {
            if(!alias.is_string()||!component(alias))return false;
            aliases+=alias.get<std::string>()+",";
        }
        if(aliases.back()==',')aliases.pop_back();
        aliases+='\n';
        if(!vectors.empty()) {
            auto svg=read(vectors/"scalable/places/folder-paper.svg");
            const std::string marker="<!-- foxml:folder-badge -->";
            const auto pos=svg.find(marker);
            if(pos==std::string::npos)return false;
            svg.replace(pos,marker.size(),"<text x=\"24\" y=\"34\" text-anchor=\"middle\" font-family=\""+xml(family["font"])+"\" font-size=\"15\" fill=\""+xml(ink)+"\">"+xml(folder["glyph"])+"</text>");
            if(!write(vectors/"scalable/places"/(asset+".svg"),svg))return false;
        }
    }
    const auto note=family["families"][0]["glyph"];
    const auto directory=family["directory"]["glyph"],link=family["symlink"]["glyph"];
    icon_rules+="]\nexts = [\n"+ext_rules+"]\nconds = [\n";
    for(const auto& pair:std::vector<std::pair<std::string,json>>{{"link",link},{"dir",directory},{"!dir",note}})
        icon_rules+="    { if = "+json_string(pair.first)+", text = "+json_string(pair.second.get<std::string>()+"  ")+", fg = "+json_string(accent)+" },\n";
    icon_rules+="]\n";
    if(!eza.empty()&&fs::exists(eza)) {
        auto theme=json::parse(read(eza),nullptr,false);
        if(!theme.is_object())return false;
        theme["extensions"]=extension_map;theme["filenames"]=names;
        theme["_foxml"]={{"enabled",family["enabled"]},{"icon",{{"style",{{"foreground",accent}}}}},{"directory",{{"glyph",directory},{"style",{{"foreground",accent}}}}},{"symlink",{{"glyph",link},{"style",{{"foreground",accent}}}}}};
        theme["_foxml"]["directories"]=directories;
        if(!write(eza,theme.dump(2)+'\n'))return false;
    }
    if(!nvim.empty()&&fs::exists(nvim)) {
        std::string rules;
        for(const auto& pair:std::vector<std::pair<std::string,std::string>>{
            {"folder_closed","glyph"},{"folder_open","open_glyph"},
            {"folder_empty","empty_glyph"},{"folder_empty_open","empty_open_glyph"}}) {
            if(!family["directory"].contains(pair.second)||!family["directory"][pair.second].is_string())return false;
            rules+="          "+pair.first+" = "+json_string(family["directory"][pair.second])+",\n";
        }
        if(!block(nvim,"tree-folders",rules))return false;
    }
    if(!yazi.empty()&&fs::exists(yazi)&&!block(yazi,"icon-family",icon_rules))return false;
    if(!init.empty()&&fs::exists(init)) {
        std::string lua="  local paper_icons = {\n";
        for(const auto& key:{"directory","symlink"})lua+="    "+std::string(key)+" = { text = "+json_string(family[key]["glyph"].get<std::string>()+"  ")+", fg = "+json_string(accent)+" },\n";
        lua+="    directories = {\n";
        for(auto it=directories.begin();it!=directories.end();++it)
            lua+="      ["+json_string(it.key())+"] = { text = "+json_string(it.value()["glyph"].get<std::string>()+"  ")+", fg = "+json_string(ink)+" },\n";
        lua+="    },\n";
        if(!block(init,"icon-family",lua+"  }\n"))return false;
    }
    if(!vectors.empty()) {
        const auto emblem=family["readonly"].value("asset",std::string());
        if(!component(emblem))return false;
        aliases+=emblem+"=";
        for(const auto& alias:family["readonly"]["aliases"]) {
            if(!alias.is_string()||!component(alias))return false;
            aliases+=alias.get<std::string>()+",";
        }
        if(aliases.back()==',')aliases.pop_back();
        aliases+='\n';
        if(!block(vectors/"index.theme","icon-aliases",aliases))return false;
        const auto svg="<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"48\" height=\"48\" viewBox=\"0 0 48 48\"><circle cx=\"24\" cy=\"24\" r=\"21\" fill=\""+xml(family["blush"])+"\" stroke=\""+xml(family["paper"])+"\" stroke-width=\"3\"/><path d=\"M15 23h18v14H15Zm4 0v-6a5 5 0 0 1 10 0v6m-5 5v4\" fill=\"none\" stroke=\""+xml(ink)+"\" stroke-width=\"2.6\" stroke-linejoin=\"round\" stroke-linecap=\"round\"/></svg>\n";
        if(!write(vectors/"scalable/emblems"/(emblem+".svg"),svg))return false;

    }
    return true;
}
}
