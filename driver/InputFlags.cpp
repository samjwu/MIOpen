/*******************************************************************************
 *
 * MIT License
 *
 * Copyright (c) 2017 Advanced Micro Devices, Inc.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 *
 *******************************************************************************/
#include "InputFlags.hpp"
#include <iomanip>
#include <iostream>
#include <vector>

InputFlags::InputFlags() { AddInputFlag("help", 'h', "", "Print Help Message", "string"); }

void InputFlags::AddInputFlag(const std::string& _long_name,
                              char _short_name,
                              const std::string& _value,
                              const std::string& _help_text,
                              const std::string& _type)
{
    Input in;
    in.long_name  = _long_name;
    in.short_name = _short_name;
    in.value      = _value;
    in.help_text  = _help_text;
    in.type       = _type;

    if(MapInputs.count(_short_name) > 0)
        printf("Input flag: %s (%c) already exists !", _long_name.c_str(), _short_name);
    else
        MapInputs[_short_name] = in;
}

[[gnu::noreturn]] void InputFlags::Print() const
{
    printf("MIOpen Driver Input Flags: \n\n");

    for(auto& content : MapInputs)
        std::cout << std::setw(8) << "--" << content.second.long_name
                  << std::setw(20 - content.second.long_name.length()) << "-" << content.first
                  << std::setw(8) << " " << content.second.help_text << "\n";
    exit(0);
}

char InputFlags::FindShortName(const std::string& long_name) const
{
    char short_name = '\0';

    for(auto& content : MapInputs)
    {
        if(content.second.long_name == long_name)
            short_name = content.first;
    }
    if(short_name == '\0')
    {
        std::cout << "Long Name: " << long_name << " Not Found !";
        exit(0);
    }

    return short_name;
}

void InputFlags::Parse(int argc, char* argv[])
{
    std::vector<std::string> args;
    for(int i = 2; i < argc; i++)
        args.push_back(argv[i]);

    //	if(args.size() == 0) // No Input Flag
    //		Print();

    for(int i = 0; i < args.size(); i++)
    {
        std::string temp = args[i];
        if(temp[0] != '-')
        {
            printf("Illegal input flag\n");
            Print();
        }
        else if(temp[0] == '-' && temp[1] == '-') // Long Name Input
        {
            std::string long_name = temp.substr(2);
            if(long_name == "help")
                Print();

            char short_name = FindShortName(long_name);

            MapInputs[short_name].value = args[i + 1];
            i++;
        }
        else if(temp[0] == '-' && temp[1] == '?') // Help Input
            Print();
        else // Short Name Input
        {
            char short_name = temp[1];
            if(MapInputs.find(short_name) == MapInputs.end())
            {
                std::cout << "Input Flag: " << short_name << " Not Found !";
                exit(0);
            }
            if(short_name == 'h')
                Print();

            if(i + 1 >= args.size()) // Check whether last arg has a value
                Print();
            else
            {
                MapInputs[short_name].value = args[i + 1];
                i++;
            }
        }
    }
}

std::string InputFlags::GetValueStr(const std::string& long_name) const
{
    char short_name   = FindShortName(long_name);
    std::string value = MapInputs.at(short_name).value;

    return value;
}

int InputFlags::GetValueInt(const std::string& long_name) const
{
    char short_name = FindShortName(long_name);
    int value       = atoi(MapInputs.at(short_name).value.c_str());

    return value;
}

uint64_t InputFlags::GetValueUint64(const std::string& long_name) const
{
    char short_name = FindShortName(long_name);
    uint64_t value  = strtoull(MapInputs.at(short_name).value.c_str(), nullptr, 10);

    return value;
}

double InputFlags::GetValueDouble(const std::string& long_name) const
{
    char short_name = FindShortName(long_name);
    double value    = atof(MapInputs.at(short_name).value.c_str());

    return value;
}
