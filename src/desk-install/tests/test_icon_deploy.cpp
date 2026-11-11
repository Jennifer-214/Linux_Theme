#include "../core/backup.hpp"
#include "../../desk-common/shell.hpp"
#include "../modules/gtk_appearance.hpp"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <unistd.h>
namespace fs=std::filesystem;
namespace desk_install {
void run_symlinks(Context&);
namespace state {bool rendered_is_current(const Context&){return true;}}
}
void put(const fs::path& p,const std::string& s){fs::create_directories(p.parent_path());std::ofstream(p)<<s;}
std::string read(const fs::path& p){std::ifstream f(p);return {std::istreambuf_iterator<char>(f),{}};}
int main(){
    char pattern[]="/tmp/fox-icon-deploy-XXXXXX";const char* created=::mkdtemp(pattern);if(!created)return 1;
    fs::path root(created);desk_install::Context ctx;
    ctx.home=root/"home";ctx.config_home=ctx.home/".config";ctx.backup_dir=root/"backup";
    ctx.rendered_dir=root/"rendered";ctx.shared_dir=root/"shared";ctx.palette_path=root/"palette.sh";
    ctx.render_ran=true;ctx.render_ok=true;fs::create_directories(ctx.shared_dir);
    put(ctx.palette_path,"LITTLE_DETAILS=fox-little-details-on\nGTK_ICON_THEME=FoxML-Paper\n");
    const auto icons=ctx.rendered_dir/"icons/foxml-paper";
    put(icons/"index.theme","[Icon Theme]\nName=FoxML-Paper\nDirectories=scalable/mimetypes\n[scalable/mimetypes]\nSize=48\nType=Scalable\nContext=MimeTypes\n[FoxML Aliases]\nfoxml-test=application-x-test,text-x-test\n");
    put(icons/"scalable/mimetypes/foxml-test.svg","new vector");
    put(icons/"scalable/mimetypes/foxml-test-symbolic.svg","small symbolic vector");
    const auto target=ctx.home/".local/share/icons/FoxML-Paper/scalable/mimetypes/application-x-test.svg";
    put(target,"old vector");
    for(const auto& p:{"eza/theme.yml","yazi/theme.toml","yazi/init.lua","ripgrep/config","hyprland/hyprtoolkit.conf","qt/gtk-palette.json"})put(ctx.rendered_dir/p,"new config");
    const auto config=ctx.config_home/"yazi/init.lua";put(config,"old user styling");
    desk_install::run_symlinks(ctx);
    bool ok=read(target)=="new vector"&&read(ctx.backup_dir/".local/share/icons/FoxML-Paper/scalable/mimetypes/application-x-test.svg")=="old vector";
    ok&=read(config)=="new config"&&read(ctx.backup_dir/".config/yazi/init.lua")=="old user styling";
    ok&=read(target.parent_path()/"application-x-test-symbolic.svg")=="small symbolic vector";
    ok&=read(ctx.config_home/"ripgrep/config")=="new config";
    ok&=read(ctx.config_home/"foxml/qt-palette.json")=="new config";
    desk_install::run_symlinks(ctx);
    ok&=read(ctx.backup_dir/".config/yazi/init.lua")=="old user styling";
    const auto cache=ctx.home/".local/share/icons/FoxML-Paper/icon-theme.cache";
    if(desk_install::sh::have("gtk-update-icon-cache")) {
        put(ctx.config_home/"gtk-3.0/settings.ini","[Settings]\ngtk-icon-theme-name=FoxML-Paper\n");
        put(cache,"old cache");desk_install::refresh_gtk_icon_cache(ctx);
        ok&=read(ctx.backup_dir/".local/share/icons/FoxML-Paper/icon-theme.cache")=="old cache";
        ok&=read(cache)!="old cache";
    }
    // A backup failure must preserve the live file, including generated assets.
    ctx.backup_dir=root/"not-a-directory";put(ctx.backup_dir,"blocked");put(target,"keep this vector");
    desk_install::run_symlinks(ctx);ok&=read(target)=="keep this vector";
    put(cache,"keep this cache");desk_install::refresh_gtk_icon_cache(ctx);ok&=read(cache)=="keep this cache";
    fs::remove_all(root);std::cout<<(ok?"Icon/config backup deployment: OK\n":"Icon/config backup deployment: FAILED\n");return ok?0:1;
}
