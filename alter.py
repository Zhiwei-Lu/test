# -*- coding: utf-8 -*-
"""
Spyder Editor

This is a temporary script file.
"""

def alter(file,old_str_1,new_str_1,old_str_2,new_str_2):
     file_data = ""
     with open(file, "r") as f:        
        for line in f:
            if old_str_1 in line:
                line = line.replace(old_str_1,new_str_1)
            if old_str_2 in line:
                line = line.replace(old_str_2,new_str_2)
            file_data += line
     with open(file,"w") as f:
         f.write(file_data)
 
alter("POSCAR", "TTT", "T T T","FFF","F F F")