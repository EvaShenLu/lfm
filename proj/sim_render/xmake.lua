add_rules("mode.release", "mode.debug")

includes("./../../src/engine/xmake.lua")
includes("./../../src/lfm/xmake.lua")

add_requires("vulkansdk", "glfw 3.4", "glm 1.0.1")
add_requires("glslang 1.3", { configs = { binaryonly = true } })
add_requires("imgui 1.91.1",  {configs = {glfw_vulkan = true}})
add_requires("cuda", {system=true, configs={utils={"cublas","cusparse","cusolver"}}})
-- On Windows use vcpkg VTK to avoid xmake VTK build and version mismatch (vcpkg has 9.3.0)
if is_plat("windows") then
    add_requires("vcpkg::vtk", {alias = "vtk"})
else
    add_requires("vtk 9.3.1")
end

set_policy("build.intermediate_directory", false)
set_runtimes("MD")
target("sim_render")
    if is_plat("windows") then
        add_rules("plugin.vsxmake.autoupdate")
        add_cxxflags("/utf-8")
        -- Windows system libs required by vcpkg FFmpeg, Boost, and CRT
        add_syslinks("Bcrypt", "Ole32", "Mfplat", "mfuuid", "Strmiids", "Secur32", "Crypt32", "Ncrypt", "User32", "ws2_32")
        add_ldflags("/NODEFAULTLIB:LIBCMT", {force = true})
    end
    add_rules("utils.glsl2spv", { outputdir = "build" })

    set_languages("cxx20")
    set_kind("binary")

    add_headerfiles("*.h")
    add_files("*.cpp")
    add_files("*.cu")
    add_includedirs(".",{public=true})

    add_cugencodes("compute_75")
    add_cuflags("--std c++20", "-lineinfo")

    add_deps("engine")
    add_deps("lfm")
    
    add_packages("imgui")
    add_packages("vulkansdk", "glfw", "glm")
    add_packages("cuda")
    add_packages("vtk")

    if is_mode("debug") then
        add_cxxflags("-DDEBUG")
    end
    if is_mode("release") then
        add_cxxflags("-DNDEBUG")
    end
    -- Copy vcpkg DLLs to build dir so sim_render.exe finds VTK, FFmpeg, etc. at runtime
    after_build(function (target)
        if is_plat("windows") then
            local vcpkg_root = get_config("vcpkg") or os.getenv("VCPKG_ROOT")
            if vcpkg_root and os.isdir(vcpkg_root) then
                local vcpkg_bin = path.join(vcpkg_root, "installed", "x64-windows", "bin")
                if os.isdir(vcpkg_bin) then
                    local outdir = target:targetdir()
                    os.cp(path.join(vcpkg_bin, "*.dll"), outdir)
                end
            end
        end
    end)
